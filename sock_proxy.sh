#!/bin/bash

# =================================================================
# Linux 全局 Socks5 代理配置脚本 (Tun2Socks方案)
# 适配：Ubuntu/Debian/CentOS
# 特性：策略路由防SSH断连、开机自启、支持无密码Socks5
# =================================================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

# 核心变量
T2S_VERSION="2.5.2"
T2S_FILE="tun2socks-linux-amd64.zip"
# 如果GitHub被封，您可以修改此URL为可访问的镜像源，或者手动上传文件到 /tmp/
DOWNLOAD_URL="https://github.com/xjasonlyu/tun2socks/releases/download/v${T2S_VERSION}/${T2S_FILE}"
INSTALL_PATH="/usr/local/bin/tun2socks"
CONFIG_DIR="/etc/tun2socks"
SERVICE_FILE="/etc/systemd/system/tun2socks.service"

# 检查是否为Root用户
[[ $EUID -ne 0 ]] && echo -e "${RED}错误: 必须使用 root 用户运行此脚本！${PLAIN}" && exit 1

# 安装依赖
check_dependencies() {
    # 新增 iptables 依赖，用于标记 SSH 流量
    if ! command -v wget &> /dev/null || ! command -v unzip &> /dev/null || ! command -v ip &> /dev/null || ! command -v iptables &> /dev/null; then
        echo -e "${YELLOW}正在尝试安装必要依赖 (wget, unzip, iproute2, iptables)...${PLAIN}"
        if [ -x "$(command -v apt)" ]; then
            apt update -y && apt install wget unzip iproute2 iptables -y
        elif [ -x "$(command -v yum)" ]; then
            yum install wget unzip iproute iptables-services -y
        else
            echo -e "${RED}无法自动安装依赖，请手动安装 wget, unzip, iproute2 和 iptables。${PLAIN}"
        fi
    fi
}

# 获取网关和默认网卡
get_network_info() {
    DEFAULT_GATEWAY=$(ip route show default | awk '/default/ {print $3}')
    DEFAULT_INTERFACE=$(ip route show default | awk '/default/ {print $5}')
}

# 安装并配置
install_proxy() {
    check_dependencies
    get_network_info

    echo -e "${GREEN}>>> 请输入 Socks5 代理信息 ${PLAIN}"
    read -p "Socks5 IP地址: " PROXY_IP
    read -p "Socks5 端口: " PROXY_PORT
    read -p "用户名 (无则直接回车): " PROXY_USER
    read -p "密码 (无则直接回车): " PROXY_PASS
    
    echo -e "${GREEN}>>> 请配置 SSH 防断连 ${PLAIN}"
    read -p "请输入您的 SSH 连接端口 (默认 22): " SSH_PORT
    [[ -z "$SSH_PORT" ]] && SSH_PORT=22

    if [[ -z "$PROXY_IP" || -z "$PROXY_PORT" ]]; then
        echo -e "${RED}IP和端口不能为空！${PLAIN}"
        exit 1
    fi

    # 构建代理URL
    if [[ -z "$PROXY_USER" ]]; then
        PROXY_URL="socks5://${PROXY_IP}:${PROXY_PORT}"
    else
        PROXY_URL="socks5://${PROXY_USER}:${PROXY_PASS}@${PROXY_IP}:${PROXY_PORT}"
    fi

    # 下载 tun2socks
    echo -e "${YELLOW}正在准备 tun2socks 核心组件...${PLAIN}"
    
    if [[ -f "$INSTALL_PATH" ]]; then
        echo -e "${GREEN}检测到 tun2socks 已安装，跳过下载。${PLAIN}"
    else
        # 考虑到端口封禁，先检查是否已手动上传
        if [[ -f "/tmp/$T2S_FILE" ]]; then
            echo -e "${GREEN}在 /tmp/ 检测到安装包，使用本地文件。${PLAIN}"
            cp "/tmp/$T2S_FILE" ./$T2S_FILE
        else
            echo -e "${YELLOW}尝试从 GitHub 下载 (如果服务器封禁443端口将失败)...${PLAIN}"
            wget --no-check-certificate -O "$T2S_FILE" "$DOWNLOAD_URL"
            if [[ $? -ne 0 ]]; then
                echo -e "${RED}下载失败！${PLAIN}"
                echo -e "${YELLOW}您的服务器可能封禁了 443 端口。${PLAIN}"
                echo -e "解决方法: 请手动下载 ${GREEN}tun2socks-linux-amd64.zip${PLAIN}"
                echo -e "然后上传到服务器的 ${GREEN}/tmp/${PLAIN} 目录，再次运行此脚本。"
                rm -f "$T2S_FILE"
                exit 1
            fi
        fi

        unzip -o "$T2S_FILE"
        mv tun2socks-linux-amd64 "$INSTALL_PATH"
        chmod +x "$INSTALL_PATH"
        rm -f "$T2S_FILE"
    fi

    # 创建配置目录
    mkdir -p "$CONFIG_DIR"

    # 生成启动脚本 (用于处理复杂的路由)
    # 我们不直接在service里写命令，而是用脚本包裹，以便处理路由表
    cat > "$CONFIG_DIR/start_tun.sh" <<EOF
#!/bin/bash
# 启动 tun2socks
$INSTALL_PATH -device tun0 -proxy $PROXY_URL &
PID=\$!

# 等待 tun0 设备创建
echo "Waiting for tun0..."
while ! ip link show tun0 >/dev/null 2>&1; do
    sleep 0.5
done

# 启动网卡并设置IP (tun2socks 不需要真实IP，但接口需要UP)
ip link set tun0 up
ip addr add 198.18.0.1/15 dev tun0

echo "Configuring routes..."

# 1. 保持 Socks5 代理服务器地址走直连 (防止死循环)
ip route add $PROXY_IP via $DEFAULT_GATEWAY dev $DEFAULT_INTERFACE metric 10

# 2. 全局流量走 tun0
ip route add 0.0.0.0/1 dev tun0
ip route add 128.0.0.0/1 dev tun0

# 3. [核心] SSH 防断连策略路由
# 逻辑：凡是源端口为 $SSH_PORT 的TCP包，打上标记 55，然后强制走物理网关
echo "Setting up SSH bypass for port $SSH_PORT..."

# 创建路由表 100，指向物理网关
ip route add default via $DEFAULT_GATEWAY dev $DEFAULT_INTERFACE table 100

# 添加策略：标记 55 的包查表 100
ip rule add fwmark 55 table 100

# 添加防火墙标记：TCP 源端口 $SSH_PORT -> 标记 55
iptables -t mangle -A OUTPUT -p tcp --sport $SSH_PORT -j MARK --set-mark 55

# 保持前台运行
wait \$PID
EOF

    # 生成停止脚本 (恢复路由)
    cat > "$CONFIG_DIR/stop_tun.sh" <<EOF
#!/bin/bash
# 清理 iptables 标记
iptables -t mangle -D OUTPUT -p tcp --sport $SSH_PORT -j MARK --set-mark 55 2>/dev/null

# 清理路由策略
ip rule del fwmark 55 table 100 2>/dev/null
ip route flush table 100 2>/dev/null

# 删除常规路由规则
ip route del 0.0.0.0/1 dev tun0 2>/dev/null
ip route del 128.0.0.0/1 dev tun0 2>/dev/null
ip route del $PROXY_IP via $DEFAULT_GATEWAY dev $DEFAULT_INTERFACE 2>/dev/null

# 杀掉进程
pkill -f "$INSTALL_PATH"
EOF

    chmod +x "$CONFIG_DIR/start_tun.sh"
    chmod +x "$CONFIG_DIR/stop_tun.sh"

    # 创建 Systemd 服务
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Tun2Socks Global Proxy
After=network.target

[Service]
Type=simple
ExecStart=$CONFIG_DIR/start_tun.sh
ExecStop=$CONFIG_DIR/stop_tun.sh
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

    # 重新加载并启动
    systemctl daemon-reload
    systemctl enable tun2socks
    systemctl start tun2socks

    echo -e "${GREEN}安装完成！代理已启动并设置开机自启。${PLAIN}"
    echo -e "${YELLOW}SSH 端口 $SSH_PORT 的流量已强制配置为直连，不再受代理影响。${PLAIN}"
    echo -e "检查状态: systemctl status tun2socks"
}

# 卸载功能
uninstall_proxy() {
    echo -e "${YELLOW}正在停止服务并清理...${PLAIN}"
    systemctl stop tun2socks
    systemctl disable tun2socks
    rm -f "$SERVICE_FILE"
    systemctl daemon-reload
    
    # 运行一次停止脚本确保路由清理干净
    if [[ -f "$CONFIG_DIR/stop_tun.sh" ]]; then
        bash "$CONFIG_DIR/stop_tun.sh"
    fi

    rm -rf "$CONFIG_DIR"
    rm -f "$INSTALL_PATH"
    
    echo -e "${GREEN}卸载完成，路由已恢复默认。${PLAIN}"
}

# 启动功能
start_proxy() {
    if [[ ! -f "$SERVICE_FILE" ]]; then
        echo -e "${RED}未检测到安装文件，请先执行选项 [1] 进行安装！${PLAIN}"
        return
    fi
    echo -e "${YELLOW}正在启动 Socks 反代...${PLAIN}"
    systemctl start tun2socks
    sleep 1
    if systemctl is-active --quiet tun2socks; then
        echo -e "${GREEN}启动成功！${PLAIN}"
    else
        echo -e "${RED}启动失败，请检查配置。${PLAIN}"
    fi
}

# 停止功能
stop_proxy() {
    if [[ ! -f "$SERVICE_FILE" ]]; then
        echo -e "${RED}未检测到安装文件，无需停止。${PLAIN}"
        return
    fi
    echo -e "${YELLOW}正在停止 Socks 反代...${PLAIN}"
    systemctl stop tun2socks
    echo -e "${GREEN}服务已停止，网络已恢复直连。${PLAIN}"
}

# 重启功能
restart_proxy() {
    if [[ ! -f "$SERVICE_FILE" ]]; then
        echo -e "${RED}未检测到安装文件，请先执行选项 [1] 进行安装！${PLAIN}"
        return
    fi
    echo -e "${YELLOW}正在重启 Socks 反代...${PLAIN}"
    systemctl restart tun2socks
    sleep 1
    if systemctl is-active --quiet tun2socks; then
        echo -e "${GREEN}重启成功！${PLAIN}"
    else
        echo -e "${RED}重启失败，请检查日志。${PLAIN}"
    fi
}

# 菜单界面
clear
echo -e "---------------------------------------------------"
echo -e "${GREEN}   Linux 全局 Socks5 代理连接脚本 (Tun2Socks)   ${PLAIN}"
echo -e "---------------------------------------------------"
echo -e "1. 安装 Sock 反代并开机自启"
echo -e "2. 卸载 Sock 反代并删除自启"
echo -e "3. 启动 Sock 反代"
echo -e "4. 停止 Sock 反代"
echo -e "5. 重启 Sock 反代"
echo -e "6. 退出脚本"
echo -e "---------------------------------------------------"
echo -e "${YELLOW}注意: 您的服务器封禁了 443/80 端口，如果自动下载失败，${PLAIN}"
echo -e "${YELLOW}请手动上传 tun2socks-linux-amd64.zip 到 /tmp/ 目录${PLAIN}"
echo -e "---------------------------------------------------"

read -p "请输入选项 [1-6]: " choice

case "$choice" in
    1)
        install_proxy
        ;;
    2)
        uninstall_proxy
        ;;
    3)
        start_proxy
        ;;
    4)
        stop_proxy
        ;;
    5)
        restart_proxy
        ;;
    6)
        exit 0
        ;;
    *)
        echo -e "${RED}无效选项${PLAIN}"
        exit 1
        ;;
esac

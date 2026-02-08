#!/bin/bash
#
# nanabot v2.0 - Oyster Republic Edge Agent
# 一键安装脚本 for Android (Termux) / Linux
# 
# 使用方法:
#   curl -fsSL https://nanabot.oyster.ai/install.sh | bash
#   或本地运行: bash install-nanabot.sh
#

set -e

# 颜色配置
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 配置
INSTALL_DIR="${HOME}/nanabot"
VENV_DIR="${INSTALL_DIR}/venv"
CONFIG_DIR="${INSTALL_DIR}/config"
LOGS_DIR="${INSTALL_DIR}/logs"
SERVICE_NAME="nanabot"
GITHUB_RAW="https://raw.githubusercontent.com/oysterrepublic/nanabot/main"

# 打印函数
print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[OK]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# 检查是否在 Termux 环境
is_termux() {
    [ -n "$TERMUX_VERSION" ] || [ -d "/data/data/com.termux" ]
}

# 检查依赖
check_dependencies() {
    print_info "检查依赖..."
    
    local deps_missing=()
    
    if ! command -v python3 &> /dev/null; then
        deps_missing+=("python3")
    fi
    
    if ! command -v pip3 &> /dev/null && ! command -v pip &> /dev/null; then
        deps_missing+=("pip")
    fi
    
    if ! command -v git &> /dev/null; then
        deps_missing+=("git")
    fi
    
    if [ ${#deps_missing[@]} -ne 0 ]; then
        print_error "缺少依赖: ${deps_missing[*]}"
        
        if is_termux; then
            print_info "在 Termux 中安装依赖..."
            pkg update -y
            pkg install -y python git openssl
        else
            print_error "请手动安装缺少的依赖"
            exit 1
        fi
    fi
    
    print_success "依赖检查通过"
}

# 创建目录结构
setup_directories() {
    print_info "创建目录结构..."
    
    mkdir -p "${INSTALL_DIR}"/{bin,config,logs,lib}
    mkdir -p "${CONFIG_DIR}"
    mkdir -p "${LOGS_DIR}"
    
    print_success "目录创建完成: ${INSTALL_DIR}"
}

# 创建虚拟环境
setup_venv() {
    print_info "创建 Python 虚拟环境..."
    
    if [ -d "${VENV_DIR}" ]; then
        print_warning "虚拟环境已存在，跳过创建"
        return
    fi
    
    python3 -m venv "${VENV_DIR}"
    
    # 激活虚拟环境并安装依赖
    source "${VENV_DIR}/bin/activate"
    
    print_info "升级 pip..."
    pip install --upgrade pip
    
    print_info "安装依赖包..."
    pip install websockets aiohttp requests
    
    deactivate
    print_success "虚拟环境创建完成"
}

# 生成设备ID
generate_device_id() {
    if command -v openssl &> /dev/null; then
        openssl rand -hex 16
    else
        cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "nanabot-$(date +%s)-$$"
    fi
}

# 创建主程序
create_main_program() {
    print_info "创建 nanabot 主程序..."
    
    local device_id=$(generate_device_id)
    
    cat > "${INSTALL_DIR}/bin/nanabot.py" << 'PYTHON_EOF'
#!/usr/bin/env python3
"""
nanabot v2.0 - Oyster Republic Edge Agent
轻量级边缘计算节点，连接 Oyster Gateway
"""

import asyncio
import json
import logging
import os
import sys
import time
import uuid
from datetime import datetime
from pathlib import Path

import aiohttp
import websockets

# 配置
INSTALL_DIR = Path.home() / "nanabot"
CONFIG_FILE = INSTALL_DIR / "config" / "nanabot.json"
LOGS_DIR = INSTALL_DIR / "logs"

# 日志配置
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    handlers=[
        logging.FileHandler(LOGS_DIR / "nanabot.log"),
        logging.StreamHandler(sys.stdout)
    ]
)
logger = logging.getLogger("nanabot")


class Nanabot:
    """Oyster Republic Edge Agent"""
    
    def __init__(self):
        self.config = self.load_config()
        self.device_id = self.config.get("device_id", str(uuid.uuid4()))
        self.gateway_url = self.config.get("gateway_url", "wss://gateway.oyster.ai/ws")
        self.enabled = self.config.get("enabled", False)
        self.reconnect_delay = 5
        self.max_reconnect_delay = 300
        self.ws = None
        self.running = False
        
    def load_config(self):
        """加载配置"""
        if CONFIG_FILE.exists():
            with open(CONFIG_FILE, 'r') as f:
                return json.load(f)
        return self.create_default_config()
    
    def create_default_config(self):
        """创建默认配置"""
        config = {
            "device_id": str(uuid.uuid4()),
            "device_name": f"nanabot-{os.uname().nodename}",
            "gateway_url": "wss://gateway.oyster.ai/ws",
            "enabled": False,
            "heartbeat_interval": 30,
            "capabilities": {
                "sensors": ["battery", "cpu", "memory", "network"],
                "actions": ["execute", "notify", "collect"]
            },
            "auth_token": None
        }
        self.save_config(config)
        return config
    
    def save_config(self, config):
        """保存配置"""
        CONFIG_FILE.parent.mkdir(parents=True, exist_ok=True)
        with open(CONFIG_FILE, 'w') as f:
            json.dump(config, f, indent=2)
    
    async def collect_metrics(self):
        """收集设备指标"""
        metrics = {
            "timestamp": datetime.utcnow().isoformat(),
            "device_id": self.device_id,
            "type": "metrics"
        }
        
        # 尝试获取电池信息 (Termux/Android)
        try:
            if Path("/sys/class/power_supply/battery/capacity").exists():
                with open("/sys/class/power_supply/battery/capacity", 'r') as f:
                    metrics["battery"] = int(f.read().strip())
        except:
            pass
        
        # 获取系统负载
        try:
            with open("/proc/loadavg", 'r') as f:
                load = f.read().strip().split()
                metrics["cpu_load"] = float(load[0])
        except:
            pass
        
        # 获取内存信息
        try:
            with open("/proc/meminfo", 'r') as f:
                meminfo = f.read()
                for line in meminfo.split('\n'):
                    if 'MemTotal' in line:
                        metrics["memory_total"] = int(line.split()[1])
                    elif 'MemAvailable' in line:
                        metrics["memory_available"] = int(line.split()[1])
        except:
            pass
        
        return metrics
    
    async def handle_command(self, message):
        """处理来自 Gateway 的命令"""
        try:
            cmd = json.loads(message)
            cmd_type = cmd.get("type")
            
            logger.info(f"收到命令: {cmd_type}")
            
            if cmd_type == "ping":
                return {"type": "pong", "timestamp": datetime.utcnow().isoformat()}
            
            elif cmd_type == "execute":
                # 执行 shell 命令
                import subprocess
                command = cmd.get("command", "")
                try:
                    result = subprocess.run(
                        command, 
                        shell=True, 
                        capture_output=True, 
                        text=True, 
                        timeout=30
                    )
                    return {
                        "type": "execute_result",
                        "stdout": result.stdout,
                        "stderr": result.stderr,
                        "returncode": result.returncode
                    }
                except subprocess.TimeoutExpired:
                    return {"type": "error", "message": "Command timeout"}
            
            elif cmd_type == "get_metrics":
                return await self.collect_metrics()
            
            elif cmd_type == "update_config":
                # 更新配置
                new_config = cmd.get("config", {})
                self.config.update(new_config)
                self.save_config(self.config)
                return {"type": "config_updated", "config": self.config}
            
            else:
                return {"type": "error", "message": f"Unknown command: {cmd_type}"}
                
        except json.JSONDecodeError:
            return {"type": "error", "message": "Invalid JSON"}
        except Exception as e:
            logger.error(f"处理命令错误: {e}")
            return {"type": "error", "message": str(e)}
    
    async def connect(self):
        """连接 Gateway"""
        if not self.enabled:
            logger.warning("nanabot 未启用，请在配置中设置 enabled: true")
            return False
        
        try:
            logger.info(f"连接 Gateway: {self.gateway_url}")
            
            headers = {
                "X-Device-ID": self.device_id,
                "X-Device-Name": self.config.get("device_name", "unknown")
            }
            
            if self.config.get("auth_token"):
                headers["Authorization"] = f"Bearer {self.config['auth_token']}"
            
            self.ws = await websockets.connect(
                self.gateway_url,
                extra_headers=headers,
                ping_interval=20,
                ping_timeout=10
            )
            
            # 发送注册信息
            await self.ws.send(json.dumps({
                "type": "register",
                "device_id": self.device_id,
                "device_name": self.config.get("device_name"),
                "capabilities": self.config.get("capabilities", {}),
                "timestamp": datetime.utcnow().isoformat()
            }))
            
            logger.info("连接成功")
            self.reconnect_delay = 5  # 重置重连延迟
            return True
            
        except Exception as e:
            logger.error(f"连接失败: {e}")
            return False
    
    async def run(self):
        """主循环"""
        self.running = True
        logger.info("nanabot 启动...")
        
        while self.running:
            try:
                if await self.connect():
                    async for message in self.ws:
                        try:
                            response = await self.handle_command(message)
                            if response:
                                await self.ws.send(json.dumps(response))
                        except Exception as e:
                            logger.error(f"处理消息错误: {e}")
                
                # 断开连接，等待重连
                if self.running:
                    logger.info(f"{self.reconnect_delay}秒后重连...")
                    await asyncio.sleep(self.reconnect_delay)
                    self.reconnect_delay = min(self.reconnect_delay * 2, self.max_reconnect_delay)
                    
            except Exception as e:
                logger.error(f"连接错误: {e}")
                await asyncio.sleep(self.reconnect_delay)
    
    def stop(self):
        """停止服务"""
        logger.info("nanabot 停止...")
        self.running = False


def main():
    """入口函数"""
    import signal
    
    bot = Nanabot()
    
    def signal_handler(sig, frame):
        print('\n收到停止信号...')
        bot.stop()
        sys.exit(0)
    
    signal.signal(signal.SIGINT, signal_handler)
    signal.signal(signal.SIGTERM, signal_handler)
    
    try:
        asyncio.run(bot.run())
    except KeyboardInterrupt:
        print('\n用户中断')
    except Exception as e:
        logger.error(f"运行错误: {e}")
        sys.exit(1)


if __name__ == "__main__":
    main()
PYTHON_EOF

    chmod +x "${INSTALL_DIR}/bin/nanabot.py"
    print_success "主程序创建完成"
}

# 创建配置文件
create_config() {
    print_info "创建配置文件..."
    
    local device_id=$(generate_device_id)
    
    cat > "${CONFIG_DIR}/nanabot.json" << EOF
{
  "device_id": "${device_id}",
  "device_name": "nanabot-$(hostname | cut -d. -f1)",
  "gateway_url": "wss://gateway.oyster.ai/ws",
  "enabled": false,
  "heartbeat_interval": 30,
  "capabilities": {
    "sensors": ["battery", "cpu", "memory", "network"],
    "actions": ["execute", "notify", "collect"]
  },
  "auth_token": null
}
EOF

    print_success "配置创建完成"
    print_info "设备ID: ${device_id}"
}

# 创建启动脚本
create_launcher_scripts() {
    print_info "创建启动脚本..."
    
    # 主启动脚本
    cat > "${INSTALL_DIR}/bin/nanabot-start" << 'EOF'
#!/bin/bash
INSTALL_DIR="${HOME}/nanabot"
VENV_DIR="${INSTALL_DIR}/venv"

if [ ! -d "${VENV_DIR}" ]; then
    echo "错误: 虚拟环境不存在，请重新安装"
    exit 1
fi

source "${VENV_DIR}/bin/activate"

# 检查是否已在运行
if pgrep -f "nanabot.py" > /dev/null; then
    echo "nanobot 已经在运行"
    exit 0
fi

echo "启动 nanabot..."
nohup python3 "${INSTALL_DIR}/bin/nanabot.py" > "${INSTALL_DIR}/logs/nanabot.out" 2>&1 &
sleep 2

if pgrep -f "nanabot.py" > /dev/null; then
    echo "✓ nanabot 启动成功"
    echo "查看日志: tail -f ${INSTALL_DIR}/logs/nanabot.log"
else
    echo "✗ 启动失败，查看日志: ${INSTALL_DIR}/logs/nanabot.out"
    exit 1
fi
EOF

    # 停止脚本
    cat > "${INSTALL_DIR}/bin/nanabot-stop" << 'EOF'
#!/bin/bash
echo "停止 nanabot..."
pkill -f "nanabot.py" 2>/dev/null || true
echo "✓ nanabot 已停止"
EOF

    # 状态脚本
    cat > "${INSTALL_DIR}/bin/nanabot-status" << 'EOF'
#!/bin/bash
INSTALL_DIR="${HOME}/nanabot"

if pgrep -f "nanabot.py" > /dev/null; then
    echo "✓ nanabot 运行中"
    echo "PID: $(pgrep -f "nanabot.py")"
    echo "日志: tail -f ${INSTALL_DIR}/logs/nanabot.log"
else
    echo "✗ nanabot 未运行"
fi
EOF

    # 添加执行权限
    chmod +x "${INSTALL_DIR}/bin/nanabot-"*
    
    # 创建全局快捷命令
    if is_termux; then
        # Termux 环境
        if [ -d "$PREFIX/bin" ]; then
            ln -sf "${INSTALL_DIR}/bin/nanabot-start" "$PREFIX/bin/nanabot-start" 2>/dev/null || true
            ln -sf "${INSTALL_DIR}/bin/nanabot-stop" "$PREFIX/bin/nanabot-stop" 2>/dev/null || true
            ln -sf "${INSTALL_DIR}/bin/nanabot-status" "$PREFIX/bin/nanabot-status" 2>/dev/null || true
        fi
    else
        # 标准 Linux
        if [ -d "$HOME/.local/bin" ]; then
            mkdir -p "$HOME/.local/bin"
            ln -sf "${INSTALL_DIR}/bin/nanabot-start" "$HOME/.local/bin/nanabot-start" 2>/dev/null || true
            ln -sf "${INSTALL_DIR}/bin/nanabot-stop" "$HOME/.local/bin/nanabot-stop" 2>/dev/null || true
            ln -sf "${INSTALL_DIR}/bin/nanabot-status" "$HOME/.local/bin/nanabot-status" 2>/dev/null || true
        fi
    fi
    
    print_success "启动脚本创建完成"
}

# 创建 Termux 服务
create_termux_service() {
    if ! is_termux; then
        return
    fi
    
    print_info "创建 Termux 后台服务..."
    
    mkdir -p "$HOME/.termux/boot"
    
    cat > "$HOME/.termux/boot/nanabot" << 'EOF'
#!/data/data/com.termux/files/usr/bin/sh
# Termux 开机启动 nanabot
termux-wake-lock
$HOME/nanabot/bin/nanabot-start
EOF

    chmod +x "$HOME/.termux/boot/nanabot"
    print_success "Termux 开机服务创建完成"
}

# 显示安装信息
show_info() {
    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}   nanabot v2.0 安装完成${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "安装目录: ${BLUE}${INSTALL_DIR}${NC}"
    echo -e "配置文件: ${BLUE}${CONFIG_DIR}/nanabot.json${NC}"
    echo -e "日志文件: ${BLUE}${LOGS_DIR}/nanabot.log${NC}"
    echo ""
    echo -e "${YELLOW}⚠️  重要：请先编辑配置文件启用 nanabot${NC}"
    echo ""
    echo "步骤 1: 编辑配置"
    echo -e "   ${BLUE}nano ${CONFIG_DIR}/nanabot.json${NC}"
    echo ""
    echo "步骤 2: 修改以下配置"
    echo '   {'
    echo '     "enabled": true,          // 启用服务'
    echo '     "auth_token": "your_token_here"  // 添加认证令牌'
    echo '   }'
    echo ""
    echo "步骤 3: 启动服务"
    echo -e "   ${BLUE}nanabot-start${NC}"
    echo ""
    echo "常用命令:"
    echo -e "   ${BLUE}nanabot-start${NC}   - 启动服务"
    echo -e "   ${BLUE}nanabot-stop${NC}    - 停止服务"
    echo -e "   ${BLUE}nanabot-status${NC}  - 查看状态"
    echo -e "   ${BLUE}tail -f ${LOGS_DIR}/nanabot.log${NC}  - 查看日志"
    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# 主安装流程
main() {
    echo -e "${BLUE}"
    echo "┌─────────────────────────────────────────┐"
    echo "│      nanabot v2.0 安装程序              │"
    echo "│      Oyster Republic Edge Agent         │"
    echo "└─────────────────────────────────────────┘"
    echo -e "${NC}"
    
    print_info "开始安装..."
    
    check_dependencies
    setup_directories
    setup_venv
    create_main_program
    create_config
    create_launcher_scripts
    create_termux_service
    
    show_info
    
    print_success "安装完成！"
}

# 运行安装
main "$@"

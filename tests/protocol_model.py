#!/usr/bin/env python3
"""KISTOY / 迷路 (MILU) BLE 协议参考实现.

来源: Kistoy_1.65.0_APKPure.apk -> com.vince.kissone.blueUtils.{EnDesCommand,BleControl}
本文件用于生成测试向量, 并与 Android mock 端的 Java 实现做交叉校验。
"""
from __future__ import annotations

# EnDesCommand.KeyTab, 4 行 x 12 列, 有符号 byte 展开为无符号
KEY_TAB = [
    [0x00, 0x18, 0x98, 0xF7, 0xA5, 0x3D, 0x0D, 0x29, 0x25, 0x50, 0x44, 0x46],
    [0x00, 0x45, 0x6E, 0x6A, 0x6F, 0x78, 0x20, 0x53, 0x2D, 0x31, 0x2E, 0x37],
    [0x00, 0x65, 0x78, 0x20, 0x54, 0x6F, 0x79, 0x73, 0x0A, 0x8E, 0x9D, 0xA3],
    [0x00, 0xC5, 0xD6, 0xE7, 0xF8, 0x0A, 0x32, 0x20, 0x6F, 0x62, 0x0D, 0x0A],
]

FRAME_HEADER = 0x23   # '#'  发送帧固定首字节
CMD_HEADER = 0x5A     # 'Z'  命令数组首字节


def _tab_key(prev: int, i: int) -> int:
    return KEY_TAB[prev & 3][i]


def encrypt(plain: bytes) -> bytes:
    """EnDesCommand.Encrypt: 12 字节明文 -> 12 字节密文."""
    assert len(plain) == 12
    out = bytearray(12)
    b0 = plain[0]
    out[0] = b0
    for i in range(1, 12):
        k = _tab_key(out[i - 1], i)
        out[i] = (((k ^ b0) ^ plain[i]) + k) & 0xFF
    return bytes(out)


def decrypt(cipher: bytes) -> bytes:
    """EnDesCommand.decrypt: 12 字节密文 -> 12 字节明文."""
    assert len(cipher) == 12
    out = bytearray(12)
    b0 = cipher[0]
    out[0] = b0
    for i in range(1, 12):
        k = _tab_key(cipher[i - 1], i)
        out[i] = (k ^ ((cipher[i] - k) & 0xFF) ^ b0) & 0xFF
    return bytes(out)


def checksum(buf: bytes, n: int) -> int:
    return sum(buf[:n]) & 0xFF


def build_command(cmd: int, p1: int = 0, p2: int = 0) -> bytes:
    """构造 12 字节命令帧 (App -> 设备, 写 0x1001).

    明文布局:
        0  : 0x23
        1  : 0x5A
        2  : 0x00
        3  : 0x00
        4  : 0x01
        5  : cmd
        6  : p1
        7  : p2
        8-10: 0x00
        11 : checksum = sum(plain[0:11]) & 0xFF
    """
    plain = bytearray(12)
    plain[0] = FRAME_HEADER
    plain[1] = CMD_HEADER
    plain[2] = 0x00
    plain[3] = 0x00
    plain[4] = 0x01
    plain[5] = cmd & 0xFF
    plain[6] = p1 & 0xFF
    plain[7] = p2 & 0xFF
    plain[11] = checksum(plain, 11)
    return encrypt(bytes(plain))


def build_notify(cmd: int, payload: bytes = b"") -> bytes:
    """构造 12 字节通知帧 (设备 -> App, notify 0x1002).

    App 侧 (BleControl.onCharacteristicChanged) 解析明文:
        [2]    = cmd   (0xB1 电量+加热档, 0xB3 ADC)
        [4]    = 电量 / ADC 低字节
        [5]    = ADC 高字节
        [6]    = 加热档
    payload 从偏移 4 开始铺开; 偏移 3 含义未知, 保持 0。
    """
    plain = bytearray(12)
    plain[0] = FRAME_HEADER
    plain[1] = CMD_HEADER
    plain[2] = cmd & 0xFF
    plain[4:4 + len(payload)] = payload[:8]
    plain[11] = checksum(plain, 11)
    return encrypt(bytes(plain))


def build_battery_notify(battery: int, hot: int) -> bytes:
    """0xB1: [4]=电量 [6]=加热档."""
    return build_notify(NOTIFY_BATTERY, bytes([battery & 0xFF, 0, hot & 0xFF]))


def build_adc_notify(adc: int) -> bytes:
    """0xB3: [4]=低字节 [5]=高字节."""
    return build_notify(NOTIFY_ADC, bytes([adc & 0xFF, (adc >> 8) & 0xFF]))


def parse_command(cipher: bytes) -> dict:
    """解析 App 发来的 12 字节密文帧."""
    if len(cipher) != 12:
        raise ValueError(f"frame length {len(cipher)}, expected 12")
    plain = decrypt(cipher)
    return {
        "plain": plain,
        "header": plain[0],
        "cmd": plain[5],
        "p1": plain[6],
        "p2": plain[7],
        "checksum": plain[11],
        "checksum_ok": plain[11] == checksum(plain, 11),
    }


# ---------------------------------------------------------------------------
# 命令表 (来自 BleControl)
# ---------------------------------------------------------------------------
CMD_MADA = 0x31          # 强度 / 震动档 (1 参)
CMD_SHAKE2 = 0x32        # 第二路震动档 (1 参)
CMD_XI_AND_SHAKE = 0x33  # 吮吸 + 震动 (2 参)
CMD_DUAL = 0x40          # 双通道: p1=0x03, p2=A 通道, 以及 B 通道放在下一字节
CMD_BENG_STATE = 0x50    # 摇摆状态
CMD_PUMP = 0x60          # 伸缩泵 + 强度
CMD_CHOUCHA = 0x71       # 吮吸
CMD_HOT = 0x80           # 加热档

NOTIFY_BATTERY = 0xB1
NOTIFY_ADC = 0xB3


def build_dual(channel_a: int, channel_b: int) -> bytes:
    """0x40 双通道帧: 明文 [5]=0x40 [6]=0x03 [7]=A [8]=B."""
    plain = bytearray(12)
    plain[0] = FRAME_HEADER
    plain[1] = CMD_HEADER
    plain[4] = 0x01
    plain[5] = CMD_DUAL
    plain[6] = 0x03
    plain[7] = channel_a & 0xFF
    plain[8] = channel_b & 0xFF
    plain[11] = checksum(plain, 11)
    return encrypt(bytes(plain))


def build_pump(intensity: int, pump: int) -> bytes:
    """0x60: 明文 [5]=0x60 [6]=0x03 [7]=pump [8]=intensity."""
    plain = bytearray(12)
    plain[0] = FRAME_HEADER
    plain[1] = CMD_HEADER
    plain[4] = 0x01
    plain[5] = CMD_PUMP
    plain[6] = 0x03
    plain[7] = pump & 0xFF
    plain[8] = intensity & 0xFF
    plain[11] = checksum(plain, 11)
    return encrypt(bytes(plain))


def hexs(b: bytes) -> str:
    return " ".join(f"{x:02X}" for x in b)


if __name__ == "__main__":
    # 自检: 加解密互逆
    for probe in (bytes(12), bytes(range(12)), bytes([0x23, 0x5A] + [0] * 9 + [0x77])):
        assert decrypt(encrypt(probe)) == probe

    print("== KeyTab ==")
    for i, row in enumerate(KEY_TAB):
        print(f"  row{i}: " + hexs(bytes(row)))

    print("\n== 命令帧 (明文 / 密文, 写入 00001001) ==")
    cases = [
        ("0x31 强度=0", build_command(CMD_MADA, 0)),
        ("0x31 强度=50", build_command(CMD_MADA, 50)),
        ("0x31 强度=100", build_command(CMD_MADA, 100)),
        ("0x32 震动2=80", build_command(CMD_SHAKE2, 80)),
        ("0x33 吮吸+震动", build_command(CMD_XI_AND_SHAKE, 60, 40)),
        ("0x40 双通道 30/70", build_dual(30, 70)),
        ("0x50 摇摆=1", build_command(CMD_BENG_STATE, 1)),
        ("0x60 泵", build_pump(90, 2)),
        ("0x71 吮吸=45", build_command(CMD_CHOUCHA, 45)),
        ("0x80 加热=3", build_command(CMD_HOT, 3)),
    ]
    for name, cipher in cases:
        print(f"  {name:22s} {hexs(decrypt(cipher))}  |  {hexs(cipher)}")

    print("\n== 通知帧 (明文 / 密文, notify 00001002) ==")
    n1 = build_battery_notify(88, 2)
    n2 = build_adc_notify(300)
    print(f"  0xB1 电量=88 加热=2    {hexs(decrypt(n1))}  |  {hexs(n1)}")
    print(f"  0xB3 ADC=300          {hexs(decrypt(n2))}  |  {hexs(n2)}")

    print("\n== 回环解析 ==")
    for name, cipher in cases:
        print(f"  {name:22s} -> {parse_command(cipher)}")

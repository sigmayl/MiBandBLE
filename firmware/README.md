# 构建输入

这两个文件不随仓库分发，请自行从目标设备固件中取出后放在本目录，或用
`tools/build.py --firmware` / `--template` 指定其他路径。

| 文件 | 说明 | SHA-256 |
|---|---|---|
| `vela_ap.bin` | 固件中的 AP 载荷（构建会校验该哈希） | `fb726472416e99ba11d1c20ce8f0d4f0831a6e9a673d63bb5918e2c3921d8845` |
| `watchface-template.bin` | 模板表盘容器的 `resource.bin`，用于重打包安装包 | `5a065e845d4da2478e71f109789bfa1d5bf080b46393a121357045913253602c` |

安装包由 `tools/watchface.py` 在这个模板容器上原地改写，因此模板必须与上表哈希一致。

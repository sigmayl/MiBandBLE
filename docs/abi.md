# o66cn BLE 客户端 ABI 核对

固件：`vela_ap.bin`，SHA-256 `fb726472416e99ba11d1c20ce8f0d4f0831a6e9a673d63bb5918e2c3921d8845`。
地址均为代码视图、已含 Thumb 位。数据视图相差 `0x20000000`。
这些绑定只对本项目的桥接载荷有效，不对其他固件版本或其他功能面作保证。

## 请求入口

| 入口 | 签名/用途 | 核对依据 |
|---|---|---|
| `0x0c4cc9b1` | `void *instance_create(void)` | bttool main `0x0c4d8fc4`；内部 176 B instance、独立 socket/loop |
| `0x0c4c6529` | `int create(instance, void **out, callbacks*)` | bttool create `0x0c4d5918`；IPC 109 |
| `0x0c50548d` | `int connect(client, uint8_t address[6])` | bttool connect `0x0c4d6da8`；IPC 111，地址类型 255 自动 |
| `0x0c4c6625` | `int disconnect(client)` | bttool disconnect `0x0c4d6e14`；IPC 112 |
| `0x0c4c6651` | `int discover(client, uuid20* or NULL)` | bttool discover `0x0c4d6e64`；IPC 113 |
| `0x0c4c6691` | `int attribute(client, uint16_t handle, uint8_t out[32])` | bttool discover callback `0x0c4d56e4`；IPC 114 |
| `0x0c4c66cd` | `int read(client, uint16_t handle)` | bttool read `0x0c4d85a0`；IPC 116 |
| `0x0c4c68cb` | `int write(client, uint16_t handle, data*, uint16_t len)` | bttool write `0x0c4d8600`；IPC 118；上限 514，深拷贝 |
| `0x0c4c66fb` | `int subscribe(client, uint16_t handle, uint16_t enable)` | bttool CCCD `0x0c4d8714`；IPC 119；0/1 |
| `0x0c4cc829` | `void *scan(instance, params8*, filter16*, callbacks*)` | bttool scan `0x0c4d7c20`；IPC 213 |
| `0x0c4c6ec3` | `int stop_scan(instance, scan_cookie)` | bttool stop `0x0c4cf354`；IPC 214；异步释放 cookie |

请求经 `0x0c4c6038`：612 B 消息，串行 socket send 与 semaphore wait。
返回 0 仅表示请求成功；连接、发现、读写和订阅需等待相应回调。
每个入口的固件字节与 SHA-256 记录在 [abi-evidence.json](../dist/abi-evidence.json)。
参数个数以 AAPCS 寄存器和实际指令为准，不采用自动推断的栈参数数量。

create 分配 16 B client：`+0 instance; +4 callbacks; +8 server_handle; +12 out_pointer`。
成功添加到 instance+168 的列表，并写出 `*out`。因此 out 参数必须常驻，不能用临时栈变量。
本实现传 `&state.client`，保留一个 client 到重启。
`0x0c4c65c4` 的 delete 会移除列表、释放 client 并写 `*out=0`；验证版不调用它，避免异步销毁竞争。

扫描参数：`+0 u32 mode; +4 u8 legacy; +5 u8 type; +6 u8 phy; +7 pad`。
当前取 mode=1、legacy=1、active=1、phy=0；filter 16 B 全零（禁用过滤）。
6 字节地址按小端保存，显示时从 `[5]` 到 `[0]`，与固件 `0x0c4c4f70` 一致。

## 回调和数据布局

GATT callbacks 大小 52 字节，首字为 size，余下 12 个函数指针。
下列回调由固件 `0x0c4c7e0c` 派发；参数与真实分支仿真交叉验证。

| 表偏移 | 回调 | IPC 事件 |
|---|---|---|
| +4 | `connected(client,address6*)` | 258 |
| +8 | `disconnected(client,address6*)` | 259 |
| +12 | `discovered(client,u8 status,uuid20*,u16 first,u16 last)`；last 在栈 | 260 |
| +16 | `read(client,u8 status,u16 handle,data*,u16 len)`；len 在栈 | 262 |
| +20 | `written(client,u8 status,u16 handle)` | 263 |
| +24 | `subscribed(client,u8 status,u16 handle,u8 enabled)` | 264 |
| +28 | `notify(client,u16 handle,data*,u16 len)` | 265 |

其余指针为 NULL；dispatcher 检查后跳过。
服务发现以 UUID 第一个字节为 0 的回调结束，不能把第一个服务回调视为发现完成。
UUID 20 B：`+0 u8 type` 为字节长度 **2 / 4 / 16**，`+4 union`。
固件 `0x0c4c5a18` 将 16/32 位 UUID 扩展到 Bluetooth base，`0x0c4c5a78` 构造 type=2。
属性 32 B：`+0 u16 handle; +4 uuid20; +24 u8 type; +28 u32 properties`。
属性 type：**0 primary、1 secondary、2 include、3 characteristic、4 descriptor**。
依据为 bttool `0x0c4d573e` 读取 type 后的 `0x0c4d5744` TBB 分支：
表 `0x0c4d5748` 的五字节为 `03 54 57 5a 5d`，依次跳到
`0x0c4d574e / 0x0c4d57f0 / 0x0c4d57f6 / 0x0c4d57fc / 0x0c4d5802`，
打印 `[PRI] / [SND] / [INC] / [CHR] / [DES]`。固件测试执行此真实分支核对所有五项。
R1/R2 曾误把 type=2 当作 characteristic，导致实际特征被全部跳过；R3 已修正。

扫描 callbacks 大小 16 B：size、`result(cookie,result*)`、`started(cookie,u8 status)`、`stopped(cookie)`。
result：地址6、地址类型u8、RSSI i8、广告类型u8、PHY u8、长度u8、广告字节。
原始服务消息广告数据从 envelope+72 开始，dispatcher 重排为 result+11。
`0x0c4c835a` 派发 started；失败时 callback 后 free；`0x0c4c837c` 派发 stopped 后 free。
桥接层在回调返回前复制所有数据，绝不保留这些临时参数指针。

## 系统与共享内存

- `0x0c121d75` Umem zalloc；`0x0c121dc9` 是 malloc，不清零；`0x0c11eee9` free；`0x0c11ed99` usleep。
- `0x0c11372d` 初始化 20 B spawn attr；`0x0c50fce9` 为 system() 同一路径的
  `nxposix_spawn(name, entry, file_actions, attr, argv, envp)`，返回 pid 或负 errno。
  调用者 `0x0c1c13b4` 证明参数排列。attr flags=4、priority=100、stack(+12)=8192。
  使用独立任务，使 BLE instance 的 getpid 注册不依赖临时 shell；内部 BLE loop 可创建其自己的线程。
- 缓存清理与执行权限沿用已核实的同步 native loader；不修改 MPU 或固件代码。

共享 state：

| 偏移 | 字段 |
|---|---|
| 32–44 | magic、version、image_size、image_crc |
| 48–60 | worker status、后台 error、request seq、ack seq |
| 64–76 | command、arg0、arg1、length |
| 80–595 | 请求数据区（最多 514 字节） |
| 596–632 | heartbeat、closing、connected、scanning、head、tail、dropped、generation、ack_generation、ack_error |
| 636–644 | notify_head、notify_dropped、notify_lock |
| 648 | ui_suspended：Lua 写 1 暂停前台租约，恢复前先 heartbeat 再写 0 |
| 652–700 | control_seq/handle/count/pos/waiting/inflight_seq/inflight_handle/done/result/ticks/armed/shutdown/stop |
| 704–739 | 当前批次帧（最多三帧，每帧 12 B） |
| 740–775 | 断开前使用的三帧归零命令 |
| 1024 | 16 × 544 B 控制事件槽：type/status/a/b/length/generation 各 u32，然后数据 |
| 9728–10103 | instance/client/scan、任务、回调表、控制生产锁、扫描去重表 |
| 10104 | 16 × 548 B 通知槽：u32 sequence + 与控制事件相同的 544 B Event |

R6 state version 为 `0x10004`，总长仍为 18872 字节；不复用 R5 `0x10003`、R4 `0x10002` 或 R2/R3 `0x10001`。
原生通知回调只写通知缓冲，不占用控制 FIFO 或控制生产锁。
notify_head 是递增 u32 位置，槽为 `head % 16`；写入先以 seq_cst 发布奇数忙序号，
填充 Event 后 release 发布偶数 `(head + 1) * 2`，最后发布新 head。计算均按 u32 回绕。
Lua 从 head 快照选择最多最新 6 条，跨多个 NSH 调用读取时比较前后序号，只有两者均等于期望偶数才交付。
被覆盖或忙槽延至下次 poll；跳过样本加 notify_dropped 显示为非致命计数。
此通知通道提供最近状态采样，不提供逐帧无损保证；控制 FIFO 的溢出仍是致命错误。

ui_suspended 为 1 时，worker 每次循环重置前台心跳静默计数并请求停止扫描，保留已建立连接。
后台无扫描、无连接建立/断开过程、无 closing、无控制批次或在途写入且 request==ack 时，管理线程 usleep 为 1000000 us；
否则仍为 100000 us。通知回调由 BLE 服务独立派发，不等待该管理线程。
closing 始终优先，后台标志不阻止显式关闭；前台 resume 先更新 heartbeat 再清后台标志，重新获得完整心跳宽限。
start 仍先关闭旧会话并清除后台标志；close 先写 closing=1 再清后台标志。

命令：1 attach、2 scan、3 stop scan、4 connect(data=address6)、5 discover、6 attribute(arg0=handle)、
7 read(arg0=handle)、8 write(arg0=handle,data)、9 subscribe(arg0=handle,arg1=0/1)、10 close。
先写参数、最后发布 request；工作线程 acquire 后读取，写 ack_error 与 generation，再 release 发布 ack。
事件生产使用无等待的原子锁和 release head；Lua 读完才前移 tail。每个请求至多一个在途。
共享状态保留到重启，回调无 Lua 依赖。

## R6 控制批次

命令 11：arg0=写句柄，data=60 B（两帧强度 + 三帧归零）。
命令 12：arg0=写句柄，data=36 B（三帧归零）。每帧为 Lua 协议模块生成的 12 B 密文。
句柄必须非零、长度精确匹配。ACK 只表示任务接受批次；event 12 的 `b=request seq`、
`a=handle`、`status=0` 才表示全部写回调成功。旧批次被替换时上报 `-125`，Lua 按序号忽略旧完成事件。

任务每次仅发送一帧，收到固件 written 回调后推进。最新批次可覆盖尚未发送的旧帧，
但不能撤回已在途写入；必须等旧写回调到达，再开始新批次。
有批次时拒绝混用命令 8（`-16`）。停止期间 Lua 禁止新的强度调整。
回调超时按 150 次 100 ms 工作等待计数；失败或超时触发关闭。
关闭且曾接受控制命令时，原生使用保存的归零帧执行停止，再断开；
内部停止事件的 request seq 为 0。停止写入失败或回调超时后仍断开，不宣称已归零。
这不构成无线链路断开或固件 IPC 阻塞时的物理停止保证。

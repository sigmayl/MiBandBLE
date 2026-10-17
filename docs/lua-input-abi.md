# R8 Lua 触摸接口核对

目标为 o66cn 3.1.28，原始 `vela_ap.bin` SHA-256：
`fb726472416e99ba11d1c20ce8f0d4f0831a6e9a673d63bb5918e2c3921d8845`。

固件未找到 `Slider` Lua 构造器字符串，因此使用两个常驻 Object 绘制轨道、填充和滑块，
监听 PRESSED / PRESSING / RELEASED / PRESS_LOST，使用已恢复的输入设备绑定取得屏幕坐标。

- `0x0c72884c` 函数表将 `get_act` 映射至 `0x0c454e61`；该包装器读取当前输入设备，
  经 `0x0c454de4` 转为 Lua userdata，空指针返回 nil。
- `0x0c460c98` 起的注册常量依次引用 `lv_indev` 名称、元方法表 `0x2c728e24`、
  实例方法表 `0x2c728e44`、模块函数表 `0x2c72884c` 和命名空间字符串 `indev`。
- `0x0c728e6c` 方法表将 `get_point` 映射至 `0x0c456e71`。
  `0x0c456e80` 调用底层点读取 `0x0c2f5530`，随后从栈偏移 0/4 取两个有符号坐标，
  分别调用 Lua pushinteger，返回值计数为 2。因此调用形式为
  `local x,y=lvgl.indev.get_act():get_point()`，不是返回坐标 table。

产品代码不调用这些固件地址，只使用现有 Lua 绑定。拖动值由轨道顶底坐标换算并限制在
0–100，保留另一通道目标值后交给已有 Session；刷新不隐藏正在触摸的轨道对象。
本地 UI 测试覆盖拖动、刷新中继续拖动、越界、松手、停止及熄屏取消，但不能替代真机触控验证。

-- KISTOY / 迷路 (MILU) 设备命令帧; 与 tests/protocol_model.py 交叉校验。
local M = {}
M.variants = { QCPW = {"吮吸", "震动"}, QCSW = {"吮吸", "震动"}, QCVW = {"震动 A", "震动 B"} }
local keys = {
    {0, 0x18, 0x98, 0xf7, 0xa5, 0x3d, 0x0d, 0x29, 0x25, 0x50, 0x44, 0x46},
    {0, 0x45, 0x6e, 0x6a, 0x6f, 0x78, 0x20, 0x53, 0x2d, 0x31, 0x2e, 0x37},
    {0, 0x65, 0x78, 0x20, 0x54, 0x6f, 0x79, 0x73, 0x0a, 0x8e, 0x9d, 0xa3},
    {0, 0xc5, 0xd6, 0xe7, 0xf8, 0x0a, 0x32, 0x20, 0x6f, 0x62, 0x0d, 0x0a},
}
local function xor(a, b) return a ~ b end
function M.encrypt(plain)
    assert(type(plain) == "string" and #plain == 12, "expected 12 bytes")
    local out = {plain:byte(1)}
    for i = 2, 12 do
        local k = keys[out[i - 1] % 4 + 1][i]
        out[i] = (xor(xor(k, out[1]), plain:byte(i)) + k) % 256
    end
    return string.char(table.unpack(out))
end
function M.decrypt(cipher)
    assert(type(cipher) == "string" and #cipher == 12, "expected 12 bytes")
    local out = {cipher:byte(1)}
    for i = 2, 12 do
        local k = keys[cipher:byte(i - 1) % 4 + 1][i]
        out[i] = xor(xor(k, (cipher:byte(i) - k) % 256), out[1])
    end
    return string.char(table.unpack(out))
end
function M.command(cmd, value)
    assert(cmd == 0x31 or cmd == 0x32 or cmd == 0x71, "unsupported command")
    assert(type(value) == "number" and value % 1 == 0 and value >= 0 and value <= 100, "invalid level")
    local p = string.char(0x23, 0x5a, 0, 0, 1, cmd, value, 0, 0, 0, 0)
    local sum = 0
    for i = 1, #p do sum = sum + p:byte(i) end
    return M.encrypt(p .. string.char(sum % 256))
end
function M.levels(variant, a, b)
    assert(M.variants[variant], "unknown variant")
    -- Call command for validation before the nonzero suction offset is applied.
    M.command(0x31, a); M.command(0x32, b)
    if variant == "QCVW" then return {M.command(0x31, a), M.command(0x32, b)} end
    return {M.command(0x32, a == 0 and 0 or math.floor(20 + a * 0.8)), M.command(0x31, b)}
end
function M.stop()
    return {M.command(0x32, 0), M.command(0x31, 0), M.command(0x71, 0)}
end
function M.hex(data)
    local out = {}
    for i = 1, #data do out[i] = string.format("%02X", data:byte(i)) end
    return table.concat(out, " ")
end
function M.unhex(text)
    local out = {}
    for v in text:gmatch("%S+") do
        if not v:match("^%x%x$") then return nil end
        out[#out + 1] = string.char(tonumber(v, 16))
    end
    return table.concat(out)
end
function M.notification(cipher)
    if type(cipher) ~= "string" or #cipher ~= 12 then return nil, "length" end
    local p = M.decrypt(cipher)
    if p:byte(1) ~= 0x23 then return nil, "header" end
    local sum = 0
    for i = 1, 11 do sum = sum + p:byte(i) end
    if sum % 256 ~= p:byte(12) then return nil, "checksum" end
    if p:byte(3) == 0xb1 then
        if p:byte(5) > 100 then return nil, "battery" end
        return {battery = p:byte(5), hot = p:byte(7)}
    elseif p:byte(3) == 0xb3 then return {adc = p:byte(5) + p:byte(6) * 256} end
    return nil, "unknown notification"
end
return M

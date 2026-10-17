-- o66cn 3.1.28, synchronous PIC loader in the existing watchface VM.
-- The retained string is never used as a hash key or modified outside its data.
local M = {}
local active = false
local function retain(value) return function() return value end end
local function check(ok, message) if not ok then error(message, 0) end end
local function pointer(value)
    local s = tostring(value)
    return tonumber(s:match("0[xX](%x+)$") or s:match(":%s*(%x+)$"), 16)
end
function M.crc32(data)
    local crc = 0xffffffff
    for i = 1, #data do
        crc = crc ~ data:byte(i)
        for _ = 1, 8 do crc = (crc >> 1) ~ (0xedb88320 & -(crc & 1)) end
    end
    return (~crc) & 0xffffffff
end
-- io_adapter: run(command)->boolean, read(path)->string|nil, remove(path).
-- Calls must be synchronous and must not yield to another loader instance.
function M.run(profile, image, input, io_adapter, progress)
    if active then return false, "native loader is already running" end
    active = true
    progress = progress or function() end
    local owner
    local path = "/tmp/o66-native-read.txt"
    local function work()
        check(profile.target_id == "xiaomi-band-10-3.1.28", "unsupported native target")
        check(_VERSION == "Lua 5.4", "requires Lua 5.4")
        check(type(debug) == "table" and type(debug.upvalueid) == "function", "debug.upvalueid unavailable")
        check(type(input) == "number" and math.type(input) == "integer"
            and input >= 0 and input <= 0xffffffff, "input must be uint32")
        check(type(image) == "string" and #image == profile.image_size and #image >= 32
            and #image <= 32768 and #image % 4 == 0 and M.crc32(image) == profile.image_crc, "native resource mismatch")
        check(image:sub(5, 8) == string.rep("\0", 4), "mailbox patch must be zero")
        local props = io_adapter.read("/etc/build.prop") or ""
        check(("\n" .. props:gsub("\r", "") .. "\n"):find("\nro.build.version=3.1.28\n", 1, true),
            "firmware version mismatch")
        local function read_words(address, count)
            check(math.type(address) == "integer" and address % 4 == 0 and count >= 1 and count <= 64,
                "invalid memory read")
            -- Remove old output first: a failed redirect must never validate stale data.
            io_adapter.remove(path)
            check(io_adapter.run(string.format("mw %08x %x > %s", address, count * 4, path)), "memory read failed")
            local text = io_adapter.read(path)
            check(type(text) == "string" and #text <= 16384, "missing memory response")
            local words = {}
            for line in text:gmatch("[^\r\n]+") do
                local a, v = line:match("^%s*([%xxX]+)%s*=%s*0[xX](%x+)%s*$")
                local parsed = a and tonumber(a:gsub("^0[xX]", ""), 16)
                check(parsed == address + #words * 4 and v and #v <= 8, "invalid memory response")
                words[#words + 1] = tonumber(v, 16)
            end
            check(#words == count, "short memory response")
            return words
        end
        local function word(address) return read_words(address, 1)[1] end
        local function write_word(address, value)
            check(io_adapter.run(string.format("mw %08x=%08x", address, value)), "memory write failed")
            check(word(address) == value, "memory write verification failed")
        end
        progress("核对固件")
        for _, span in ipairs(profile.fingerprints) do
            local actual = read_words(span.address, #span.words)
            for i, expected in ipairs(span.words) do
                check(actual[i] == expected, string.format("firmware fingerprint mismatch at %08x", span.address + (i-1)*4))
            end
        end
        progress("检查执行环境")
        check(word(0xe000ed94) == 5 and word(0xe000edc0) == 0x00447722, "unexpected MPU configuration")
        check(((word(0xe000ed90) >> 8) & 0xff) == 8 and word(profile.mpu_bitmap) == 0x0f,
            "unexpected MPU region ownership")
        check((word(0x07ffa000) & 1) == 1 and (word(0x07ffc000) & 1) == 1, "unexpected cache state")
        local heap = word(profile.umem_slot)
        check(heap == profile.umem_descriptor, "unexpected Umem descriptor")
        local lo, hi = word(heap + 0x1c), word(heap + 0x20)
        check(lo == profile.heap_start and hi == profile.heap_end, "unexpected Umem bounds")
        local function owned_range(p, n)
            return type(p) == "number" and p % 4 == 0 and p > lo and n > 0 and p + n <= hi
        end
        progress("准备原生载荷")
        -- Fresh long string, closed upvalue, and a trailing guard; GC keeps it
        -- reachable until synchronous NSH exec AND result readback finish.
        owner = retain(string.pack("<I4I4I4I4I4I4I4I4", 0x7ffffffe, 0x66310001, input, 0, 0, 0, 0, 0)
            .. image .. string.rep("\165", 32))
        local up = pointer(debug.upvalueid(owner, 1))
        check(owned_range(up, 32), "upvalue outside Umem")
        local value = word(up + 8)
        check(value == up + 16 and (word(value + 8) & 0xff) == 0x54, "unexpected closed UpVal layout")
        local object, length = word(value), #owner()
        check(owned_range(object, length + 17), "string outside Umem")
        check((word(object + 4) & 0xff) == 0x14 and word(object + 12) == length, "unexpected TString layout")
        local mailbox, code = object + 16, object + 48
        check(code % 8 == 0, "unaligned native entry")
        check(word(mailbox) == 0x7ffffffe and word(mailbox + 8) == input
            and word(code) == string.unpack("<I4", image), "owned payload mismatch")
        write_word(code + 4, mailbox)
        progress("同步缓存")
        -- These interior leaves establish their own arguments; exec's r0 is
        -- printf's result and is not a callable argument supplied by Lua.
        for _, entry in ipairs({profile.cache_d_clean, profile.cache_barrier,
                                profile.cache_i_invalidate, profile.cache_barrier}) do
            check(io_adapter.run(string.format("exec 0x%08x", entry)), "cache synchronization failed")
        end
        progress("执行原生载荷")
        local command_ok = io_adapter.run(string.format("exec 0x%08x", (code - 0x20000000) | 1))
        local result = read_words(mailbox, 8)
        check(result[8] == 0x4f36364f and result[2] == 0x66310001 and result[3] == input,
            "native completion mailbox mismatch")
        -- Guard starts after a word-aligned image (enforced by builder).
        for _, v in ipairs(read_words(code + #image, 8)) do check(v == 0xa5a5a5a5, "native payload guard damaged") end
        local rc = result[1]
        if rc >= 0x80000000 then rc = rc - 0x100000000 end
        check(rc == 0, "native payload rc=" .. rc)
        check(command_ok, "NSH exec failed")
        return {result = rc, output = result[4], control = result[5], ipsr = result[6], stack = result[7]}
    end
    local ok, result = pcall(work)
    owner = nil
    pcall(io_adapter.remove, path)
    active = false
    if not ok then return false, tostring(result) end
    return true, result
end
return M

local native=(function()
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

end)()
local profile={["schema"]=1,
["target_id"]="xiaomi-band-10-3.1.28",
["firmware_sha256"]="fb726472416e99ba11d1c20ce8f0d4f0831a6e9a673d63bb5918e2c3921d8845",
["status"]="STATIC_TEST_CANDIDATE",
["device_status"]="NOT_PROBED",
["umem_slot"]=537474728,
["umem_descriptor"]=1010003712,
["heap_start"]=1010004088,
["heap_end"]=1023344632,
["mpu_bitmap"]=537696484,
["cache_d_clean"]=207004331,
["cache_i_invalidate"]=201988127,
["cache_barrier"]=206934207,
["fingerprints"]={{["address"]=201988096,
["words"]={671199592,1258803465,4027738138,4031713025,3205104129,1671061594,536895514,1258440560,3204507634,134201344,134193152}},{["address"]=207004324,
["words"]={671199536,1258541314,1666851329,1198530560,3891874561,134201344,134193152}},{["address"]=206934204,
["words"]={4089393300,4089417551,1198559087}},{["address"]=202895432,
["words"]={1341188397,1174777987,1750091400,2936021309,4153755158,553713598,571519752,453113856,4168939413,184676431,571498616,1752178944,4168415125,251851192,3709027970,553656848,4153764016,1182922859,134279247,3943187912,3540649482,923541504,3904718525,1183027184,3890372728,151121999,1177741294,4166534696,1225404426,1201695148,251720123,1752944646,1613973032,1772841010,1201162501,1772832296,1201162500,134541576,3204507608,744797722,744797737,745856902}},{["address"]=202915340,
["words"]={2961421808,2936030742,570443268,490301552,4211668880,2972206597,1752328315,3489743514,2974513179,1768113696,1225222194,4031727512,923545855,3186640573,1772307970,1176520963,1202210712,3204507637,744801156,744802058}},{["address"]=202891484,
["words"]={1106307373,1174712450,1183860238,1746029846,1747496704,1259714824,1175576602,4083310714,1752891345,2049686000,3708437171,1225812323,1201161760,905965647,923289128,3904718525,2053865968,3657581235,1225419107,1751902192,1177634370,1201161760,4150937093,4173660133,3890807888,3889444112,744800096,202875949,744801212,744801407}},{["address"]=202915012,
["words"]={3672321280,4174964235}},{["address"]=202299912,
["words"]={1612466558,1249780482,441600126,4029968427,1266546751,1249790333,441606168,4029958269,1266546743}},{["address"]=202300420,
["words"]={1010003712,1023344640,744683009,537474728}},{["address"]=202513048,
["words"]={499955192,67629092,455809165}},{["address"]=202513148,
["words"]={4110706977,4028986300,451544327,1629570065,1642275081,4173603595,974131580,4173610248,1646600580,1780703339}},{["address"]=202800920,
["words"]={570602928,2936021249,4160701957,553779161,1177044484,4288870397,4026759683,721814335,723963911,553701386,4160636456,537001121,1745075632,4166202371,3891597348,3942737921,3891335428}},{["address"]=202853820,
["words"]={1761850800,4043392524,2936013329,1822236948,4201576444,419504640,1904369797,1623487498,3912089008}},{["address"]=202838700,
["words"]={1175238064,1175564032,34598916,4160710917,4170579927,1896095820,35188738,1839886658,1705533442,3046686128}},{["address"]=202848212,
["words"]={554246688,4160570912,4043373927,1619198736,2417555584,251983944}},{["address"]=201982540,
["words"]={1242974997,1116424470,3541321240,2404381631,2406478783,1259544832,1116949011,1259590416}},{["address"]=201982628,
["words"]={738925704,1006632960,739143048,1006850304}},{["address"]=206441496,
["words"]={4026595423,469781561}},{["address"]=201988888,
["words"]={0,131072,258,2538496,1441792,257,3491758080,65536,513}},{["address"]=206934412,
["words"]={4152931592,671152243,587382548,4089389828,1241878367,50458691,815069378,2404381631,2406478783,3171426304,3758157056}},{["address"]=207935388,
["words"]={1647210354,1684826485,1919252014,1852795251,825111357,171455022,1882091378,1969516402,1680766051,1667855973,1668492901,1852138866,1885431923,1768963429,1932356716,1701863784,1869744740,1869770798,1952675172,1986356270,778396521,1769366884,2037671267,1648190832,174354017,1932423026,1668034150,1701076836,1953067886}},{["address"]=201988124,
["words"]={1258440560,3204507634,134201344,134193152}},{["address"]=202454828,
["words"]={604026352,2936057987,1174761476,1176509753}},{["address"]=202501528,
["words"]={2961487232,2936021248,1259057552,4222634507}},{["address"]=202501864,
["words"]={1258534272,2936030721,4160710680,3179347941}},{["address"]=202513676,
["words"]={2961421712,1618587392,4282841087,2971158020}},{["address"]=202513692,
["words"]={1752834304,4180079551,923551264,3180349117}},{["address"]=202513780,
["words"]={1258796440,2936030721,4160710680,1174732741}},{["address"]=206333224,
["words"]={1106307373,2098918829,1175864968,2936030725}},{["address"]=206333476,
["words"]={4121802112,2936044826,1753461104,1744839280}},{["address"]=206333520,
["words"]={4121802128,1174699291,2981670656,1664772226}},{["address"]=206333584,
["words"]={4121802128,1175747867,2980622080,2260297859}},{["address"]=206333644,
["words"]={4121802112,2936044826,1753461112,578062009}},{["address"]=206333688,
["words"]={3045124089,2098918829,2978000640,2260297859}},{["address"]=206334152,
["words"]={3048258960,2972757760,620950080,3624026795}},{["address"]=206335680,
["words"]={3045113216,2098918829,1745596160,490283734}},{["address"]=206340896,
["words"]={4170214278,806092870,4249810009,4043589125}},{["address"]=206340952,
["words"]={4174439814,4170207560,1751847244,1755006504}},{["address"]=206340988,
["words"]={1364261072,1177053291,1201170651,4099294760}},{["address"]=206341068,
["words"]={721479664,2907370559,721447003,2907108415}},{["address"]=206341116,
["words"]={721478964,2905797695,755001565,2905535551}},{["address"]=206341180,
["words"]={4097780480,1763552531,4097780992,4172590351}},{["address"]=206341272,
["words"]={4097780480,1776135397,4097780992,1177595105}},{["address"]=206358568,
["words"]={1139861805,4121773573,2936044827,1175864968}},{["address"]=206358960,
["words"]={1206970669,548450462,4099256066,1174731227}},{["address"]=206395196,
["words"]={2117849429,3624413956,4026788063,1515672579}},{["address"]=206395212,
["words"]={2285437021,4098050097,1178663861,4098058745}},{["address"]=206395376,
["words"]={1209043001,2285496237,3886696463,1208977465}},{["address"]=206395392,
["words"]={2285496231,3886303246,745854605,745854648}},{["address"]=206395444,
["words"]={745854778,745854793,745854810,745854827}},{["address"]=206591116,
["words"]={4121802128,1174699291,2981146368,570845315}},{["address"]=206634216,
["words"]={1341188397,1182904457,1176389258,2936423956}},{["address"]=206934204,
["words"]={4089393300,4089417551,1198559087,3758157056}},{["address"]=207004328,
["words"]={1258541314,1666851329,1198530560,3891874561}}},
["image_size"]=3500,
["image_crc"]=3315623511}
local image=("00f002b80000000010b5aff20c046468eff314812161eff3058262616b46a36111f0010f07d132b913f0070f03d1204600f018f801e06ff06400206043f24f61c4f63671e161bff34f8f10bdaff250004068704721b1002200f8012b0139fbd17047d4d42de9f04788b0876882466ff01506a7f18000b0f5ff4f00f2b18017f0030040f0ad8044f6b81041f675513844c0f612418847f0b1054647f27900c3f6334085420ed315f007000bd144f6bf1007eb0508ccf2013006214044ccf2013188420bd84ef6e9612846c0f6114188476ff00d0684e06ff00b0681e00af12009002019f80010295401308742f9d1002044f6454168600420c0f20100c3f24261c8e9081048f22030c8f828704ff0ff32cef6b85029460b7882ea0306082380ea5602f40708bf7208013b1646f7d10131013ff0d1d043c5f80480c8f82c004af2ab20c0f65640804749f2bf04c0f65544a04741f61f00c0f60a408047a04703af14213846fff776ff43f22d713846c0f61141884740b14ef6e9610746c0f61141284688477e422be04ff4005002a9069046f20440adf80c00002002904ff6e947cde9001003ab1048c0f6504700227844a0eb090041190d487844b8470646b0f1ff3f07dd42f20c6048f800600026caf80c8005e04ef6e9612846c0f611418847304608b0bde8f0873f000000e60b00002de9f04f95b0fff729ff044600f51855d948da497844da4ada4b79448446da48da4e7b44da4f7a447e4478447f44c5e90b03c5e909762e46c5e90d21c5f83cc0d448d549d54a78447944e86134207a44c5e90521294646f8200f102041f8100f4cf62900c0f64c40049100f5c47080474ff418510028605000f02d8346f251610435c0f64c41a1f59473294632469847002840f0228304f1300001210595c0e8af1f42f2586004f51c7a2044039004f515704ff0000bd0e8af5f00204ff000090890069004f52271b9f1320f38bf09f10109d1e8af7f04f515712846d1e8af5f04f516766840384318bfd946b9f1320f24bf0120c6e8af0fd6e8af0f30b304f51770d0e8af0f022816d1d4f8b40298b1d4f8b802d0b9d4f890220120032104f53973c4f8b802cde900102046002100f05afc04f5167609e0204600f07ffc04f5167618b104f13401c1e8af0f04f13800d0e8af8f04f13c00d0e8af0f099780453cd004f14000d0e8af0f07950a2810d0012816d104f51770d0e8af0f30b904f51870d0e8af0f002800f08b816ff00f0515e00120c6e8af0fd4f8b40248b100250de0d6e8af1f002900f03f816ff07c0505e0204600f042fc04f51676054604f51e70c0e8af5f04f51d70dae8af1fc0e8af1f04f13c00c0e8af8f079d04f51878d8e8af0f02281ed127b906980130069064281ad3d8e8af0f022816d1032004f51851c8e8af0f46f6cb020868c0f64c42896802f5bf62904710b10220c8e8af0f04f5167601e00020069004f5177adae8af0f012808d1089801300890962824bf0120c6e8af0f01e000200890dae8af0f02282ad104f5277cdce8af0f00287bd004f52a70d0e8af1f002900f0998004f52b710027d1e8af1fc0e8afbfcce8afbfd4f89402d4f88c22d4f8a032934266d110b3002900f00f81204600f068fc04f516760120c6e8af0f16e0d4f8940230b120466ff06a0100f05afc04f5167604f527705f46c0e8afbf04f52a70c0e8afbfc4f8b4b2c4f8b8b248f2a0620998c0f20102002810462ed0d6e8af0f0028104629d1d8e8af0f0028104624d1dae8af0f012810461fd0dae8af0f032810461ad004f1380004f13c01d0e8af0fd1e8af1f884210460fd1d4f89402002810460ad104f52770d0e8af0f0028104604bf44f24020c0f20f004ef69951c0f61141884704f51c7abb46b5e6d4f8940200270028bad0d4f89812814234d12046002100f0fefb04f51676afe713090000f9080000a5080000930800006b0800004508000017080000d9070000a5070000a3060000d4f8b00200270130c4f8b002962893d320466ff06d01e34600f0d9fb04f5167639460120c4f8b472c6e8af0f0027cbe8af1f81e7d4e9a30304f52a7bc4e9a8030120c4f8b072cbe8af7fcce8af0f01eb410004f530712e4601eb8002059846f6cb0599b20c23c0f64c450068a847354604f5167600283ff45faf04f52b71c1e8af0f0120cbe8af0f56e7042866d0032847d0022840f0858004f51875d5e8af0f00287ff4a3ae04f51770d0e8af0f00287ff49cae40f2011003991390012012900020cde90c00cde90a0001f800b00130b0f5907ff9d1012004f51856c5e8af0f4cf62907306812a9049b0aaac0f64c474ff0000bb847002800f011810025b06013e1c6e8afbf5ae8000f0130cae8e10f0029f8d173e6d4f898120131c4f898124fe704f518774ff0000bd7e8af0f022856d1032004f51851c7e8af0f46f6cb020868c0f64c42896802f5bf62904700284fd005460220c7e8af0fe8e004f51870d0e8af0f00287ff441ae04f517774ff0000bd7e8af0fc0bbe06c062835d1012045f28d42c7e8af0f04f150010598c0f650420068904760b305460020c7e8af0fb7e004f51771d1e8af1f02291ad1062821dd072840d0082848d0092874d1a06c012800f2a980059846f25163c0f64c43aa330068616ca26c89b292b298471be6002504e06ff06a0519e66ff00f05099f15e600259be005284dd0062854d10aaf20213846fff75efc059846f25162c0f64c4202f140033a460068616c89b29847626c054620202946cde900700b200023099f00f069fa7be0059846f25162c0f64c427c320068616c89b22be0d4f8940200287ff4cbad04f52770d0e8af0f00287ff4c4ade06c002856d0e06c40f20221884251d8059846f6cb07c0f64c470068616ce26c89b293b204f15002b84704f51676099fc2e5059846f251620021c0f64c4200689047b7e5a0f10b01012933d8616c89b324210b2808bf3c21e26c8a422ad104f1500100220b2808bf1831a3188f5c0132242a83f8e472f8d1a0f10c030121b3fa83f3c4f8b41204f138010b28d1e8af1f626c4ff003004fea531308bf0220cde9000304f15003204600f09bf900254ff0000b0ae06ff015057fe54ff0000bc5e8afbf6ff0040504f51c7a099f04f5167673e56ff0040004f13401c1e8af0f04f130000221c0e8af1f002015b0bde8f08f2de9f04782b08946fff7aefb00f51871d1e8af1f02296ed100f51671d1e8af1f002968d199f80ac048f2203509f108024ff0ff310cf10303cef6b855177881ea0706082785ea5601f40708bf7108013f0e46f7d10132013bf0d142f2586200eb02080cf10b0c6fea010e4ff0ff3a00214546002303eb430208eb8206f28862b10127002219f80240a85c0132a04218bf0f46062af6d15fb903e0baf1000f48bf9a4601330c35182be4d10021534608e0b0687045a0eb0e00b0fa80f008bf53464109c1b9002b16d403eb4300002108eb800019f80120425401310629f9d10121c0f808e0c1800120002100220023cde9009c00f05ff902b0bde8f08770b582b0002600290c464ff0000508bf0226fff72bfb00f518702146c0e8af6f022000220023cde9005500f045f902b070bd80b582b0fff719fb00f518700021c0e8af1f032000220023cde9001100f033f902b080bd10b582b00c46fff706fb00f517700221c0e8af1f0620cde90040042000210022002300f01ef902b010bd10b582b00c46fff7f1fa00f517700021c0e8af1f0620cde9004005200022002300f00af902b010bd80b582b09c461046049b002a18bf1420cde900200620624600f0faf802b080bd80b582b00498cde900300720002300f0eff802b080bd70b582b016460c46fff7c1fa05460020cde90000082021463246002300f0ddf805f52770d0e8af0f60b1d5f8a402b04208d105f52b700121c0e8af4f05f52a70c0e8af1f02b070bd80b582b00020cde90000092000f0c1f802b080bd2de9f0411c4615460e46fff792fa40f203218c420ad300f5207050e8001f013140e80012002af8d1bde8f08100f521710122d1e8ef3f41e80027002ff9d14bb100f5207050e8001f013140e80012002af8d1e9e700f51f7c4ff40977dce8af3f4ff0000803f00f0203f1010e02fb070242f278774fea4e0300f51c703a4403f10107c2e8af7f4ff00a07d0e8af0fc2e90178c2e90368c2e905403cb102f11c0015f8016b013c00f8016bf9d1c2e8af3fcce8afefc1e8af8fbde8f0812de9f04383b0dde90a890546d0f894021c4616460f4648b1d5e9a3320020cde900000c206ff07c0100f04bf8a8eb88010020c5e9a58005f530708900c5f8bc92c5e9a37614f8012b013100f8012bf9d303b0bde8f083f0b581b000f51877054600f51856d7e8af0f02280fd1032046f6c362c7e8af0fc0f64c423068b168904720b104460220c7e8af0f00e0002405f51775d5e8af7f781e01280fd8032046f22561c5e8af0fc0f64c417068884708b1c5e8af7f002c18bf204600e0204601b0f0bd2de9f047984691468a460746fff7d2f942f25461dde9083201440124d1e8ef5f41e80046002ef9d155b100f51b7050e8001f013140e80012002af8d1bde8f08700f5197c00f51a74dce8afefd4e8af4faeeb04040f2c9cbf40f20324a24209d300f51b7050e8002f013240e80023002bf8d123e00ef00f0404eb041400eb441400f51c70d0e8af0fc4f80074c4f804a4c4f80894c4f80c84c4f81024c4f8140442b104f58060183013f8014b013a00f8014bf9d10ef10100cce8af0f0020c1e8af0fbde8f087b0b582b0d0e9a332044600200d46cde900000c20fff791ff1db1d4f8b80220b906e0d4f8bc020028f7d00020c4f8b4021db104f13400c0e8af5f0020c4f8940202b0b0bd6f36365f626c65000000"):gsub("..",function(x)return string.char(tonumber(x,16))end)
local BLE=(function()
-- Shared-memory client for the persistent native task. No Lua callback escapes.
local M={}
local function check(ok,msg) if not ok then error(msg,0) end end
local function signed(n) return n>=0x80000000 and n-0x100000000 or n end
function M.new(native,profile,image,io)
 local self={pending=nil,closed=false}
 local path='/tmp/o66-ble-read.txt'
 local lock='/tmp/o66-native-ble-lock'
 local function read(address,count)
  check(math.type(address)=='integer' and address%4==0 and count>=1 and count<=64,'invalid BLE memory read')
  io.remove(path)
  check(io.run(string.format('mw %08x %x > %s',address,count*4,path)),'BLE memory read failed')
  local text=io.read(path);check(type(text)=='string' and #text<=16384,'missing BLE memory response')
  local out={}
  for line in text:gmatch('[^\r\n]+') do
   local a,v=line:match('^%s*([%xxX]+)%s*=%s*0[xX](%x+)%s*$')
   check(a and tonumber(a:gsub('^0[xX]',''),16)==address+#out*4 and v and #v<=8,'invalid BLE memory response')
   out[#out+1]=tonumber(v,16)
  end
  check(#out==count,'short BLE memory response');return out
 end
 local function bytes(address,n)
  local parts={};local words=(n+3)//4
  for i=0,words-1,64 do
   local w=read(address+i*4,math.min(64,words-i))
   for _,v in ipairs(w)do parts[#parts+1]=string.pack('<I4',v)end
  end
  return table.concat(parts):sub(1,n)
 end
 local function write(offset,value)
  check(self.base and ((offset>=56 and offset<=628 and offset%4==0)or offset==648),'invalid BLE write')
  check(io.run(string.format('mw %08x=%08x',self.base+offset,value&0xffffffff)),'BLE memory write failed')
 end
 function self.start(progress)
  progress=progress or function()end
  local saved=io.read(lock..'/owner')
  if not saved then
   check(io.run('mkdir '..lock),'BLE 启动记录不完整，请重启手环后重试')
   local ok,r=native.run(profile,image,#image,io,progress)
   check(ok,r)
   saved=string.format('%08x %08x %d\n',r.output,profile.image_crc,#image)
   check(io.write(lock..'/owner',saved),'BLE owner record failed; reboot required')
  end
  local ptr,crc,size=saved:match('^(%x+) (%x+) (%d+)\n$')
  ptr,crc,size=tonumber(ptr,16),tonumber(crc,16),tonumber(size)
  check(ptr and crc==profile.image_crc and size==#image,'BLE 驻留版本不同，请重启后使用此版本')
  check(ptr%4==0 and ptr-size>profile.heap_start and ptr+18872<profile.heap_end,'BLE owner out of bounds')
  check(read(profile.umem_slot,1)[1]==profile.umem_descriptor,'BLE heap mismatch')
  local header=read(ptr+32,4)
  check(header[1]==0x36424c45 and header[2]==0x10004 and header[3]==size and header[4]==crc,'BLE owner mismatch')
  local code=bytes(ptr-size,size)
  check(string.unpack('<I4',code,5)==ptr,'BLE resident pointer mismatch')
  code=code:sub(1,4)..string.rep('\0',4)..code:sub(9)
  check(code==image,'BLE resident code mismatch')
  self.base=ptr;self.seq=read(ptr+56,1)[1];self.beat=read(ptr+596,1)[1]
  self.drop_base=read(ptr+620,1)[1]
  local counters=read(ptr+636,2)
  self.notify_cursor=counters[1];self.notify_drop_base=counters[2];self.notify_skipped=0
  self.closed=false
  write(600,1);write(648,0);self.heartbeat()
  return true
 end
 function self.heartbeat()
  self.beat=(self.beat+1)&0xffffffff;write(596,self.beat)
 end
 function self.suspend()
  if self.base and not self.closed then write(648,1)end
 end
 function self.resume()
  if self.base and not self.closed then self.heartbeat();write(648,0)end
 end
 function self.send(op,a,b,data)
  check(not self.closed and not self.pending,'BLE request busy or closed')
  check(math.type(op)=='integer' and op>=1 and op<=12,'invalid BLE operation')
  a,b,data=a or 0,b or 0,data or ''
  check(a>=0 and a<=65535 and b>=0 and b<=65535 and #data<=514,'invalid BLE arguments')
  local h=read(self.base+56,2);check(h[1]==h[2],'previous BLE request still pending')
  write(64,op);write(68,a);write(72,b);write(76,#data)
  data=data..string.rep('\0',-#data%4)
  for i=1,#data,4 do
   if (i-1)%64==0 then self.heartbeat()end
   write(80+i-1,string.unpack('<I4',data,i))
  end
  self.heartbeat();self.seq=(self.seq+1)&0xffffffff
  write(56,self.seq);self.pending={seq=self.seq,op=op,a=a,b=b};return self.seq
 end
 function self.poll()
  check(self.base,'BLE not started')
  if not self.closed then self.heartbeat()end
  local h=read(self.base+48,4)
  local q=read(self.base+596,12)
  local result={status=h[1],error=signed(h[2]),request=h[3],ack=h[4],closing=q[2],connected=q[3],scanning=q[4],dropped=(q[7]-self.drop_base)&0xffffffff,generation=q[8],events={}}
  if self.pending and h[4]==self.pending.seq then
   result.completed=self.pending;result.completed.rc=signed(q[10]);self.pending=nil
  end
  local head,tail=q[5],q[6]
  check(((head-tail)&0xffffffff)<=16,string.format('BLE event queue corrupted head=%08x tail=%08x state=%08x',head,tail,self.base))
  for _=1,math.min(6,(head-tail)&0xffffffff) do
   self.heartbeat()
   local address=self.base+1024+(tail%16)*544
   local e=read(address,6);check(e[5]<=514,'BLE event length corrupted')
   result.events[#result.events+1]={kind=e[1],status=signed(e[2]),a=e[3],b=e[4],generation=e[6],data=e[5]>0 and bytes(address+24,e[5]) or ''}
   tail=(tail+1)&0xffffffff;write(616,tail)
  end
  -- Sample at most the six newest notifications. The independent control FIFO
  -- above remains lossless until an actual control overflow (still fatal).
  -- Each notification slot is read under a sequence check; never accept torn
  -- payloads or block a callback while Lua is descheduled.
  local available=(q[11]-self.notify_cursor)&0xffffffff
  if available>6 then
   self.notify_skipped=self.notify_skipped+available-6
   self.notify_cursor=(q[11]-6)&0xffffffff;available=6
  end
  for _=1,available do
   self.heartbeat()
   local index=self.notify_cursor
   local address=self.base+10104+(index%16)*548
   local expected=((index+1)*2)&0xffffffff
   local e=read(address,16) -- stamp + header + first 36 bytes, one shell read
   if e[1]~=expected then break end
   local n=e[6];local data=''
   if n<=514 then
    local parts={};for i=8,16 do parts[#parts+1]=string.pack('<I4',e[i])end
    data=table.concat(parts):sub(1,n)
    if n>36 then data=data..bytes(address+64,n-36)end
   end
   if read(address,1)[1]~=expected then break end
   check(e[2]==10 and n<=514,'BLE notification slot corrupted')
   result.events[#result.events+1]={kind=10,status=signed(e[3]),a=e[4],b=e[5],generation=e[7],data=data}
   self.notify_cursor=(index+1)&0xffffffff
  end
  result.notification_skipped=self.notify_skipped+((q[12]-self.notify_drop_base)&0xffffffff)
  return result
 end
 function self.close()
  if self.base then write(600,1);write(648,0)end
  self.closed=true
 end
 return self
end
return M

end)()
local P=(function()
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

end)()
local Session=(function()
-- BLE session and product controls. An acknowledgement is not a GATT completion.
local M={}
local names={[1]='scan',[2]='scan_started',[3]='scan_stopped',[4]='connected',[5]='disconnected',[6]='discovered',[7]='read',[8]='written',[9]='subscribed',[10]='notify',[11]='attribute',[12]='control'}
local base='fb349b5f8000008000100000'
local function require_state(value,message)
 if not value then error(message,0)end
 return value
end
local function uuid(data)
 if #data~=20 or data:byte(1)==0 then return nil end
 -- 0x0c4c5a18 / 0x0c4c5a78: type is byte length 2, 4, or 16.
 if data:byte(1)==2 then return string.unpack('<I2',data,5)end
 if data:byte(1)==4 then return string.unpack('<I4',data,5)end
 local h=(data:sub(5):gsub('.',function(c)return string.format('%02x',c:byte())end))
 -- Firmware bttool prints this exact 128-bit little-endian union in reverse.
 if h:sub(1,24)==base and h:sub(29,32)=='0000' then return tonumber(h:sub(27,28)..h:sub(25,26),16)end
 return h
end
local function ad_name(data)
 local i=1
 while i<=#data do
  local n=data:byte(i);if n==0 then break end
  if n<1 or i+n>#data then return nil end
  local t=data:byte(i+1)
  if t==8 or t==9 then return data:sub(i+2,i+n):gsub('[%z\1-\31]',''):sub(1,24)end
  i=i+n+1
 end
end
function M.new(transport,protocol,log,clock)
 local s={phase='starting',message='启动原生 BLE',devices={},selected=1,notifications=0,notification_skipped=0,reads=0,writes=0,attributes=0,queue={},generation=nil,op=nil,closed=false,desired={0,0},confirmed=nil,control_state='unknown',controls_ready=false}
 log=log or function()end;clock=clock or os.time
 local deadline=clock()+20
 local services,attrs={},{}
 local function fail(message)
  s.phase='failed';s.message=message;s.queue={};s.op=nil;s.control_pending=nil;s.controls_ready=false;s.confirmed=nil;s.control_state='unknown';s.closed=true;pcall(transport.close);log('ERROR '..message)
 end
 local function enqueue(cmd,a,b,data,event,done,allow_error)
  s.queue[#s.queue+1]={cmd=cmd,a=a or 0,b=b or 0,data=data or '',event=event,done=done,allow_error=allow_error}
 end
 local function service_for(h)
  for _,v in ipairs(services)do if h>=v.first and h<=v.last then return v.uuid end end
 end
 local function ready()
  s.phase='ready';s.message='已连接，熄屏保持'
 end
 local function finish_discovery()
  if s.notify_handle then
   s.phase='subscribing';enqueue(9,s.notify_handle,1,'',9,ready)
  else ready()end
 end
 local function enumerate()
  local count=0
  for _,v in ipairs(services)do
   if v.last<v.first or v.last-v.first>255 then fail('服务范围异常');return end
   for h=v.first,v.last do
    if not attrs[h] then
     count=count+1;if count>256 then fail('属性过多，详情见日志');return end
     attrs[h]=true;enqueue(6,h,0,'',11,nil,true)
    end
   end
  end
  if count==0 then fail('未发现 GATT 服务');return end
  s.queue[#s.queue].done=finish_discovery
 end
 local function handle(e)
  log(string.format('event=%s status=%d a=%04x b=%04x data=%s',names[e.kind] or e.kind,e.status,e.a,e.b,protocol.hex(e.data)))
  if e.generation~=s.generation then return end
  if e.kind==1 and #e.data>=11 then
   local raw=e.data:sub(1,6);local address={}
   for i=6,1,-1 do address[#address+1]=string.format('%02X',raw:byte(i))end
   address=table.concat(address,':')
   local name=ad_name(e.data:sub(12,11+e.data:byte(11)))
   local found
   for _,d in ipairs(s.devices)do if d.address==address then found=d end end
   if not found and #s.devices<24 then found={raw=raw,address=address};s.devices[#s.devices+1]=found end
   if found then found.name=name or found.name or address;found.rssi=e.data:byte(8);if found.rssi>=128 then found.rssi=found.rssi-256 end end
  elseif e.kind==2 and e.status~=0 then fail('扫描启动失败 '..e.status)
  elseif e.kind==3 then if s.phase=='scanning' or s.phase=='scan_stopping' then s.phase='idle';s.message='扫描结束'end
  elseif e.kind==4 then
   if s.phase=='connecting' then
    s.phase='discovering';s.message='发现 GATT 服务';services,attrs={},{}
    enqueue(5,0,0,'',6,enumerate)
   end
  elseif e.kind==5 then
   s.phase=s.disconnect_requested and 'disconnecting' or 'idle';s.message='连接已断开';s.queue={};s.op=nil;s.target=nil
   s.write_handle,s.notify_handle,s.read_handle=nil,nil,nil
   s.control_pending=nil;s.confirmed=nil;s.controls_ready=false;s.control_state='unknown'
  elseif e.kind==6 and e.status==0 then
   local u=uuid(e.data)
   if u then services[#services+1]={first=e.a,last=e.b,uuid=u}end
  elseif e.kind==11 and e.status==0 and #e.data==32 then
   s.attributes=s.attributes+1
   local h=string.unpack('<I2',e.data);local u=uuid(e.data:sub(5,24))
   local kind=e.data:byte(25);local props=string.unpack('<I4',e.data,29)
   -- bttool's type switch at 0x0c4d5744: 0 PRI, 1 SND, 2 INC, 3 CHR, 4 DES.
   if kind==3 then
    if props&2~=0 and not s.read_handle then s.read_handle=h end
    if service_for(h)==0x1000 then
     if u==0x1001 and props&8~=0 then
      if s.write_handle and s.write_handle~=h then fail('重复的 0x1001 特征');return end
      s.write_handle=h
     elseif u==0x1002 and props&16~=0 then s.notify_handle=h end
    end
   end
  elseif e.kind==7 then
   if e.status==0 then s.reads=s.reads+1;s.last_read=protocol.hex(e.data)end
  elseif e.kind==8 and e.status==0 then s.writes=s.writes+1
  elseif e.kind==10 then
   s.notifications=s.notifications+1;s.last_notify=protocol.hex(e.data)
   local n=protocol.notification(e.data)
   if n then
    if n.battery~=nil then s.battery=n.battery end
    if n.adc~=nil then s.adc=n.adc end
   end
  end
  local op=s.op
  if op and op.event==e.kind and (e.kind==12 and e.b==op.seq or e.kind~=12 and (e.kind<7 or e.a==op.a)) then
   -- Discovery emits one callback per service and a zero-UUID completion.
   if e.kind~=6 or e.status~=0 or not uuid(e.data) then
    op.seen=true;op.event_rc=e.status
   end
  end
 end
 function s.tick()
  if s.closed or s.suspended_at then return end
  local r=transport.poll()
  if s.disconnect_requested and r.connected==0 and r.scanning==0 then
   s.closed=true;s.phase='closed';s.message='已断开';s.target=nil;s.confirmed=nil;s.controls_ready=false;return
  end
  if r.status==2 then fail('原生 BLE 初始化失败 '..r.error);return end
  if r.dropped>0 then fail('BLE 控制事件丢失 '..r.dropped..'，已请求断开');return end
  if r.notification_skipped and r.notification_skipped~=s.notification_skipped then
   s.notification_skipped=r.notification_skipped
   log('notification samples skipped='..s.notification_skipped)
  end
  if s.phase=='starting' and r.status==1 and r.request==r.ack and r.connected==0 and r.scanning==0 and not s.op then
   enqueue(1,0,0,'',nil,function()s.phase='idle';s.message='原生 BLE 就绪'end)
   s.phase='attaching'
  end
  if r.completed and s.op and r.completed.seq==s.op.seq then
   s.op.acked=true;s.op.rc=r.completed.rc
   if s.op.cmd==1 and r.completed.rc==0 then s.generation=r.generation end
  end
  for _,e in ipairs(r.events)do handle(e)end
  local op=s.op
  if op and op.acked and (op.rc~=0 or not op.event or op.seen) then
   s.op=nil
   local rc=op.rc~=0 and op.rc or (op.event_rc or 0)
   if rc~=0 and not op.allow_error then fail('BLE 操作 '..op.cmd..' 失败 '..rc);return end
   if op.done then op.done()end
  elseif op and clock()>op.deadline then fail('BLE 操作 '..op.cmd..' 超时');return end
  if s.closed then return end
  if s.control_pending and not transport.pending and (not s.op or s.op.cmd==11 or s.op.cmd==12) then
   local pending=s.control_pending;s.control_pending=nil
   s.op={cmd=pending.cmd,a=s.write_handle,b=0,data=pending.data,event=12,deadline=clock()+60}
   s.op.done=function()
    if not s.control_pending then
     s.confirmed=pending.levels;s.desired={pending.levels[1],pending.levels[2]};s.control_state='idle';s.controls_ready=true
     s.message=pending.cmd==12 and '已停止' or '强度已更新'
    end
   end
   s.op.seq=transport.send(s.op.cmd,s.op.a,0,s.op.data)
  elseif not s.op and not transport.pending and #s.queue>0 then
   s.op=table.remove(s.queue,1);s.op.seq=transport.send(s.op.cmd,s.op.a,s.op.b,s.op.data);s.op.deadline=clock()+15
  end
  if s.phase=='starting' and clock()>deadline then fail('原生工作线程启动超时')end
 end
 function s.scan()
  require_state(s.phase=='idle' and not s.op,'请等待当前操作完成')
  s.devices={};s.target=nil;s.selected=1;s.phase='scanning';s.message='扫描 10 秒';enqueue(2)
 end
 function s.connect()
  require_state(s.phase=='idle' and not s.op,'请等待扫描结束')
  local d=require_state(s.devices[s.selected],'请先扫描并选择设备')
  s.target=d;s.notifications=0;s.reads=0;s.writes=0;s.attributes=0;s.read_handle=nil;s.write_handle=nil;s.notify_handle=nil;s.adc=nil;s.battery=nil
  s.controls_ready=false;s.confirmed=nil;s.desired={0,0};s.control_state='unknown';s.control_pending=nil
  s.phase='connecting';s.message='连接 '..d.name;enqueue(4,0,0,d.raw,4)
 end
 function s.read()
  require_state(s.phase=='ready' and not s.op and #s.queue==0,'请等待连接和当前操作完成')
  require_state(s.read_handle,'该设备没有可读特征')
  s.message='正在读取特征';enqueue(7,s.read_handle,0,'',7,function()s.message='读取成功\n'..(s.last_read~='' and s.last_read or '空数据')end)
 end
 function s.write_zero()
  require_state(s.phase=='ready' and not s.op and #s.queue==0,'请等待连接和当前操作完成')
  require_state(s.write_handle,'未找到 0x1001 可写特征')
  require_state(s.target and protocol.variants[s.target.name],'零值写入仅支持 QCPW/QCSW/QCVW')
  s.message='正在写入三条零值命令'
  for _,data in ipairs(protocol.stop())do enqueue(8,s.write_handle,0,data,8)end
  s.queue[#s.queue].done=function()s.message='三条零值命令写入完成'end
 end
 function s.close()
  s.closed=true;s.queue={};s.op=nil;s.control_pending=nil;s.controls_ready=false;s.confirmed=nil;s.phase='closed';s.message='已请求停止扫描和断开';transport.close()
 end
 function s.stop_scan()
  if s.phase=='scanning' then s.phase='scan_stopping';enqueue(3)end
 end
 local function require_control()
  require_state(s.phase=='ready' and not s.closed and s.write_handle and s.target and protocol.variants[s.target.name],'设备尚未准备好')
 end
 function s.set_levels(a,b)
  require_control();require_state(s.controls_ready and s.control_state~='stopping','请等待设备停止')
  local frames=protocol.levels(s.target.name,a,b)
  s.desired={a,b};s.control_state='setting'
  s.control_pending={cmd=11,data=table.concat(frames)..table.concat(protocol.stop()),levels={a,b}}
 end
 function s.stop()
  require_control();s.desired={0,0};s.control_state='stopping'
  s.control_pending={cmd=12,data=table.concat(protocol.stop()),levels={0,0}}
 end
 function s.disconnect()
  s.disconnect_requested=true;s.queue={};s.op=nil;s.control_pending=nil;s.controls_ready=false;s.confirmed=nil;s.phase='disconnecting'
  transport.close()
 end
 function s.suspend()
  if s.closed or s.suspended_at then return end
  -- A tap may precede SCREEN_OFF before the next 250 ms UI tick. Hand the
  -- latest batch to native before Lua pauses, including a stop behind an ACK.
  local submit_deadline=clock()+2
  for _=1,64 do
   if not s.control_pending or s.closed then break end
   s.tick()
   if clock()>=submit_deadline then break end
  end
  if s.control_pending then fail('控制指令提交超时，已请求停止并断开');return end
  if s.closed then return end
  transport.suspend();s.suspended_at=clock()
 end
 function s.resume()
  if s.closed or not s.suspended_at then return end
  transport.resume()
  -- Timers measure foreground waiting, not time spent with the Lua VM paused.
  -- Queued native completions are consumed on the first tick after resume.
  local elapsed=math.max(0,clock()-s.suspended_at)
  deadline=deadline+elapsed
  if s.op then s.op.deadline=s.op.deadline+elapsed end
  s.suspended_at=nil
 end
 M.uuid=uuid;M.ad_name=ad_name
 return s
end
return M

end)()
local Display=(function()
-- Keep every message available on the small screen; never truncate an error.
local M={}
function M.message(value)
 local text=tostring(value)
 -- Strip only Lua source locations, retaining BLE status numbers and the body.
 while true do
  local clean,n=text:gsub('^.-%.lua:%d+:%s*','',1)
  if n==0 then clean,n=text:gsub('^%[string .-%]:%d+:%s*','',1)end
  text=clean;if n==0 then break end
 end
 return text:gsub('\r\n','\n'):gsub('[%z\1-\8\11-\31\127]',' ')
end
function M.pages(value,columns,rows)
 local text=M.message(value)
 local pages,lines,line={}, {}, {}
 local function flush_line()
  lines[#lines+1]=table.concat(line);line={}
  if #lines==rows then pages[#pages+1]=table.concat(lines,'\n');lines={}end
 end
 -- Count UTF-8 codepoints, conservatively allowing a full font width each.
 -- This works on the watch's Lua even without the optional utf8 library.
 for ch in text:gmatch('[\1-\127\194-\244][\128-\191]*')do
  if ch=='\n' then flush_line()
  else
   if #line==columns then flush_line()end
   line[#line+1]=ch
  end
 end
 if #line>0 or #pages==0 and #lines==0 then flush_line()end
 if #lines>0 then pages[#pages+1]=table.concat(lines,'\n')end
 return pages
end
return M

end)()
-- Product UI. One persistent root/session; navigation never tears down BLE.
local lvgl=require('lvgl')
local width,height=lvgl.HOR_RES(),lvgl.VER_RES()
local C={bg=0x101416,card=0x20282b,text=0xf3f3eb,muted=0xa1b0ad,accent=0xafd6bf,dark=0x12241a,stop=0xa54f4e}
local root=lvgl.Object(nil,{w=width,h=height,bg_color=C.bg,bg_opa=lvgl.OPA(100),border_width=0,pad_all=0})
root:clear_flag(lvgl.FLAG.SCROLLABLE)
local alive,active,busy,screen_on,visible=true,true,false,true,true
local session,transport,timer
local app={page='home',list_page=1,help_page=1,help_back='home'}
local render,protect,drag
local adapter={}
function adapter.run(cmd)local r=os.execute(cmd);return r==true or r==0 end
function adapter.read(path)local f=io.open(path,'rb');if not f then return nil end;local d=f:read(16385);f:close();return d end
function adapter.remove(path)return os.remove(path)end
function adapter.write(path,data)local f=io.open(path,'wb');if not f then return false end;local r=f:write(data);local c=f:close();return r~=nil and c~=nil end
local function log(line)
 local f=io.open('/tmp/o66-ble.log','ab');if not f then return end
 if (f:seek('end') or 0)>65536 then f:close();f=io.open('/tmp/o66-ble.log','wb')end
 if f then f:write(tostring(os.time()),' ',line,'\n');f:close()end
end
local function short(value,n)
 local chars={};for ch in tostring(value or ''):gmatch('[\1-\127\194-\244][\128-\191]*')do chars[#chars+1]=ch end
 if #chars<=n then return table.concat(chars)end
 return table.concat(chars,'',1,n-1)..'…'
end
local labels,buttons={},{}
for i=1,8 do labels[i]=lvgl.Label(root,{text='',w=width-24,h=30,text_color=C.text})end
for i=1,7 do
 local b=lvgl.Object(root,{w=width-24,h=48,bg_opa=lvgl.OPA(100),border_width=0,pad_all=0,radius=16})
 b:clear_flag(lvgl.FLAG.SCROLLABLE);b:add_flag(lvgl.FLAG.CLICKABLE)
 local t=lvgl.Label(b,{text='',text_color=C.text,align=lvgl.ALIGN.CENTER})
 local item={object=b,text=t};buttons[i]=item
 b:onevent(lvgl.EVENT.CLICKED,function()if item.enabled and item.action then protect(item.action)end end)
end
-- Wide custom sliders use the firmware's Lua indev binding (x,y returns).
-- Their hit objects remain visible throughout dragging, including UI refreshes.
local sliders={}
for i=1,2 do
 local lane={};sliders[i]=lane
 lane.object=lvgl.Object(root,{bg_color=C.card,bg_opa=lvgl.OPA(100),border_width=0,pad_all=0,radius=32})
 lane.fill=lvgl.Object(lane.object,{bg_color=C.accent,bg_opa=lvgl.OPA(100),border_width=0,pad_all=0,radius=32})
 lane.thumb=lvgl.Object(lane.object,{w=28,h=6,bg_color=C.text,bg_opa=lvgl.OPA(100),border_width=0,radius=3})
 for _,o in ipairs({lane.object,lane.fill,lane.thumb})do o:clear_flag(lvgl.FLAG.SCROLLABLE)end
 lane.fill:clear_flag(lvgl.FLAG.CLICKABLE);lane.thumb:clear_flag(lvgl.FLAG.CLICKABLE)
 lane.object:add_flag(lvgl.FLAG.CLICKABLE)
 if lvgl.FLAG.GESTURE_BUBBLE then lane.object:clear_flag(lvgl.FLAG.GESTURE_BUBBLE)end
 lane.object:onevent(lvgl.EVENT.PRESSED,function()if lane.enabled then lane.dragging=true;protect(function()drag(i)end)end end)
 lane.object:onevent(lvgl.EVENT.PRESSING,function()if lane.dragging then protect(function()drag(i)end)end end)
 lane.object:onevent(lvgl.EVENT.RELEASED,function()if lane.dragging then protect(function()drag(i)end)end;lane.dragging=false end)
 if lvgl.EVENT.PRESS_LOST then lane.object:onevent(lvgl.EVENT.PRESS_LOST,function()lane.dragging=false end)end
end
-- Fit each complete rectangle inside the capsule, with an 8 px arc margin.
-- On 212 x 520, the end caps have radius 106 and centres at y=106/414.
local function place(obj,x,y,w,h)
 y,h=math.floor(y*height/520),math.floor(h*height/520)
 local radius=width/2
 local dy=math.max(0,radius-y,y+h-(height-radius))
 local inset=math.max(16,math.ceil(radius-math.sqrt(math.max(0,(radius-8)*(radius-8)-dy*dy))))
 x=math.max(x or inset,inset);w=math.min(w or width-2*inset,width-inset-x)
 obj:set{w=w,h=h,align={type=lvgl.ALIGN.TOP_LEFT,x_ofs=x,y_ofs=y}}
 obj:clear_flag(lvgl.FLAG.HIDDEN)
end
local function text(i,value,y,size,h,color,x,w)
 local o=labels[i];place(o,x,y,w,h)
 o:set{text=value,text_font=lvgl.Font('MiSans-Regular',size),text_color=color or C.text,text_align=2}
end
local function button(i,value,y,h,action,kind,enabled,x,w)
 local b=buttons[i];b.enabled=enabled~=false;b.action=action
 place(b.object,x,y,w,h)
 b.object:set{radius=kind=='channel' and 22 or 24,bg_color=not b.enabled and 0x252b2d or kind=='primary' and C.accent or kind=='stop' and C.stop or C.card}
 b.text:set{text=value,text_font=lvgl.Font('MiSans-Regular',kind=='channel' and 24 or 18),text_align=2,text_color=not b.enabled and 0x65706d or kind=='primary' and C.dark or C.text}
end
local function go(page)app.page=page end
local function connected()return session and not session.closed and session.phase=='ready'end
local function available()return connected() and session.controls_ready end
local function supported()return connected() and session.write_handle and session.target and P.variants[session.target.name]end
local function stop()if supported() then session.stop()end end
local function help()app.help_back=app.page;app.help_page=1;go('help')end
local function problem(title,message)
 app.problem_title=title;app.problem_message=message;app.connecting=false;app.pending_device=nil;app.pending_scan=false;go('problem')
end
local function show_error(err)
 log('UI '..tostring(err))
 if tostring(err):find('重启',1,true) then problem('请重启手环','重启后再打开迷路')
 else problem('设备未响应','靠近后重试')end
end
protect=function(fn)
 if not alive or not active or busy then return end
 busy=true;local ok,err=pcall(fn);busy=false
 if not ok then show_error(err)end
 render()
end
local function start()
 if session and not session.closed then return end
 transport=BLE.new(native,profile,image,adapter)
 transport.start(function()if render then render()end end)
 session=Session.new(transport,P,log);app.initializing=false;app.was_ready=false;app.failed_session=nil
end
local function search()
 if connected() then go('device');return end
 go('devices');app.list_page=1;app.pending_device=nil;app.pending_scan=true;start()
end
local function select_device(d)
 app.last_device=d;app.pending_device=d;app.pending_scan=false;app.connecting=true;go('connecting')
 if session.phase=='scanning' then session.stop_scan()end
end
local function retry()
 if session and not session.closed then session.close()end
 if app.last_device then go('connecting');app.connecting=true;app.pending_device=app.last_device;start()
 else search()end
end
local function disconnect()
 app.pending_scan=false;app.pending_device=nil;app.connecting=false;app.was_ready=false
 if session and not session.closed then session.disconnect()end
 go('home')
end
local function back(page)button(1,'‹ 返回',26,44,function()go(page)end,nil,true,math.floor((width-96)/2),96)end
drag=function(i)
 local lane=sliders[i]
 if not lane.enabled or not available() or session.control_state=='stopping' then return end
 local input=lvgl.indev.get_act();if not input then return end
 local _,y=input:get_point();if type(y)~='number' then return end
 local value=math.max(0,math.min(100,math.floor((lane.bottom-y)*100/(lane.bottom-lane.top)+0.5)))
 if value==session.desired[i] then return end
 local levels={session.desired[1],session.desired[2]};levels[i]=value
 session.set_levels(levels[1],levels[2])
end
local function status_text()
 if not session then return '未连接'end
 if session.phase=='disconnecting' then return '断开中'end
 if session.control_state=='stopping' then return '停止中'end
 if session.control_state=='setting' then return '调整中'end
 if available() then return session.confirmed and session.confirmed[1]==0 and session.confirmed[2]==0 and '已停止' or '已连接'end
 return '未连接'
end
local help_pages={
 {'连接','开启设备\n靠近手环\n点选连接'},
 {'调节','左右独立调节\n上滑增强，下滑减弱\n停止全部归零'},
 {'熄屏','连接继续保持\n结束时进入设备页\n断开连接'},
}
render=function()
 if not alive then return end
 for _,l in ipairs(labels)do l:add_flag(lvgl.FLAG.HIDDEN)end
 for _,b in ipairs(buttons)do b.enabled=false;b.object:add_flag(lvgl.FLAG.HIDDEN)end
 local d=session and session.target or app.last_device
 local ready=available()
 local can_adjust=ready and session.control_state~='stopping'
 for _,lane in ipairs(sliders)do
  lane.enabled=app.page=='control' and can_adjust
  if not lane.enabled then lane.dragging=false end
  if app.page~='control' then lane.object:add_flag(lvgl.FLAG.HIDDEN)end
 end
 if app.page=='home' then
  local diameter=math.min(width-32,180)
  local closing=session and session.phase=='disconnecting'
  button(1,closing and '断开中' or ready and '遥控' or '连接',260-diameter*260/height,diameter*520/height,function()if ready then go('control')else search()end end,'primary',not closing,math.floor((width-diameter)/2),diameter)
  buttons[1].object:set{radius=diameter/2};buttons[1].text:set{text_font=lvgl.Font('MiSans-Regular',28)}
  button(2,'帮助',442,48,help)
 elseif app.page=='devices' then
  back('home');text(1,'选择设备',86,24,34)
  local searching=app.pending_scan or session and (session.phase=='starting' or session.phase=='attaching' or session.phase=='scanning' or session.phase=='scan_stopping')
  text(2,searching and '搜索中' or '附近设备',126,16,24,C.muted)
  local devices={};for _,v in ipairs(session and session.devices or {})do if P.variants[v.name] then devices[#devices+1]=v end end
  local total=math.max(1,math.ceil(#devices/2));app.list_page=math.min(app.list_page,total)
  if #devices==0 then text(3,searching and '开启设备\n靠近手环' or '未找到设备',210,20,64,C.muted)end
  for row=1,2 do
   local item=devices[(app.list_page-1)*2+row]
   if item then button(row+1,short(item.name,8)..'\n'..item.address:sub(-5),162+(row-1)*86,74,function()select_device(item)end)end
  end
  if total>1 then
   local half=math.floor((width-44)/2)
   button(5,'上一页',340,48,function()app.list_page=app.list_page-1 end,nil,app.list_page>1,16,half)
   button(6,'下一页',340,48,function()app.list_page=app.list_page+1 end,nil,app.list_page<total,28+half,half)
   text(4,string.format('%d / %d',app.list_page,total),398,16,24,C.muted)
  end
  button(7,searching and '停止搜索' or '重新搜索',442,48,function()
   if searching then app.pending_scan=false;if session then session.stop_scan()end else search()end
  end,'primary')
 elseif app.page=='connecting' then
  button(1,'‹ 返回',26,44,disconnect,nil,true,math.floor((width-96)/2),96)
  text(1,'连接设备',86,24,34)
  text(2,short(app.last_device and app.last_device.name or '设备',8),188,28,44)
  text(3,session and session.phase=='ready' and '准备中' or '连接中',260,20,32,C.accent)
  button(2,'取消',442,48,disconnect)
 elseif app.page=='control' then
  back('home')
  local channels=d and P.variants[d.name] or {'通道一','通道二'}
  local half=math.floor((width-44)/2)
  for i=1,2 do
   local x=16+(i-1)*(half+12);local lane=sliders[i]
   local value=ready and session.desired[i]or 0
   text(i,channels[i],88,18,28,nil,x,half)
   text(i+2,ready and tostring(value)or '—',120,30,38,C.accent,x,half)
   place(lane.object,x+math.floor((half-64)/2),162,64,174)
   local h=math.floor(174*height/520)
   lane.top=math.floor(162*height/520)+16;lane.bottom=math.floor(162*height/520)+h-16
   local thumb_y=math.floor((h-32)*(100-value)/100)+13
   local fill_h=h-thumb_y-3
   lane.fill:set{w=64,h=fill_h,bg_color=lane.enabled and C.accent or C.muted,align={type=lvgl.ALIGN.TOP_LEFT,x_ofs=0,y_ofs=h-fill_h}}
   lane.thumb:set{align={type=lvgl.ALIGN.TOP_LEFT,x_ofs=18,y_ofs=thumb_y}}
  end
  text(5,status_text(),342,16,24,C.muted)
  button(4,'停止全部',372,56,stop,'stop',supported())
  button(5,'设备',442,48,function()go('device')end)
 elseif app.page=='device' then
  back(ready and 'control' or 'home');text(1,'设备',86,24,34)
  text(2,short(d and d.name or '未连接',8),164,28,44)
  text(3,status_text(),224,18,28,C.accent)
  text(4,session and session.battery and ('电量 '..session.battery..'%')or '电量 —',272,20,32)
  button(2,'断开连接',372,56,disconnect,'stop',connected())
  button(3,'帮助',442,48,help)
 elseif app.page=='help' then
  back(app.help_back);text(1,'帮助',86,24,34)
  local page=help_pages[app.help_page]
  text(2,page[1],166,26,40,C.accent)
  text(3,page[2],234,18,90,C.muted)
  text(4,string.format('%d / %d',app.help_page,#help_pages),386,16,24,C.muted)
  button(2,'下一页',442,48,function()app.help_page=app.help_page%#help_pages+1 end,'primary')
 elseif app.page=='problem' then
  back('home');text(1,app.problem_title or '连接失败',164,24,40)
  text(2,app.problem_message or '靠近后重试',234,18,64,C.muted)
  button(2,'重新连接',372,56,retry,'primary');button(3,'更换设备',442,48,function()if session and not session.closed then session.close()end;search()end)
 end
end
local function update()
 if not alive or not active or busy then return end
 local ok,err=pcall(function()
  if session then
   session.tick()
   if session.phase=='idle' and not session.op then
    if app.pending_device then
     session.devices={app.pending_device};session.selected=1;app.pending_device=nil;session.connect()
    elseif app.pending_scan then app.pending_scan=false;session.scan()end
   end
   if connected() and app.connecting then
    if not supported() then problem('暂不支持','请更换设备');session.disconnect()
    elseif not app.initializing then app.initializing=true;session.stop()
    elseif session.controls_ready then app.connecting=false;app.was_ready=true;go('control')end
   end
   if session.phase=='failed' and app.failed_session~=session then
    app.failed_session=session;show_error(session.message)
   elseif app.was_ready and session.phase=='idle' then
    app.was_ready=false;problem('连接已断开','靠近后重连')
   elseif app.connecting and session.phase=='idle' and not app.pending_device and not session.op then
    problem('连接失败','开启设备后重试')
   end
  end
  render()
 end)
 if not ok then
  if session then pcall(session.close)elseif transport then pcall(transport.close)end
  show_error(err);render()
 end
end
local function close()
 if not alive then return end
 alive=false;active=false
 if session then pcall(session.close)elseif transport then pcall(transport.close)end
 if timer then local t=timer;timer=nil;t:delete()end
end
if lvgl.EVENT.DELETE then root:onevent(lvgl.EVENT.DELETE,close)end
timer=lvgl.Timer{period=250,repeat_count=-1,cb=update}
local function visibility_changed()
 if not alive then return end
 local next_active=screen_on and visible;if next_active==active then return end
 active=next_active
 if not active then
  app.pending_scan=false;for _,lane in ipairs(sliders)do lane.dragging=false end
  if timer then timer:pause()end
 end
 local ok,err=pcall(function()local owner=session or transport;if owner then if active then owner.resume()else owner.suspend()end end end)
 if not ok then
  if session then pcall(session.close)elseif transport then pcall(transport.close)end
  show_error(err)
 end
 if active then if timer then timer:resume()end;update()end
end
if lvgl.EVENT.SCREEN_UNLOADED and lvgl.EVENT.SCREEN_LOADED then
 root:onevent(lvgl.EVENT.SCREEN_UNLOADED,function()visible=false;visibility_changed()end)
 root:onevent(lvgl.EVENT.SCREEN_LOADED,function()visible=true;visibility_changed()end)
end
function ScreenStateChangedCB(pre,now,reason)screen_on=now=='ON';visibility_changed()end
render()

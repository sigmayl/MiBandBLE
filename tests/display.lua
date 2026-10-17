local Display=dofile('lua/display.lua')
local tests=0
local function check(v,msg)assert(v,msg);tests=tests+1 end
local body='读取失败 BLE 状态 17 '..string.rep('错误详情不能被覆盖ABC123',15)
local raw='smash.lua:998: '..body
check(Display.message(raw)==body)
check(Display.message('[string "smash.lua"]:998: '..body)==body)
check(Display.message('BLE:17: timeout')=='BLE:17: timeout')
local function verify_pages(pages,text,columns,rows)
 local recovered={}
 for _,page in ipairs(pages)do
  local n=0
  for line in (page..'\n'):gmatch('(.-)\n')do
   n=n+1;check(utf8.len(line)<=columns);recovered[#recovered+1]=line
  end
  check(n<=rows)
 end
 check(table.concat(recovered)==text:gsub('\n',''),'Every character remains reachable')
end
verify_pages(Display.pages(raw,10,3),body,10,3)
for _,text in ipairs({'','1234567890','1234567890\nabc','a\n\nb','中文\nABC'})do
 verify_pages(Display.pages(text,10,3),text,10,3)
end

-- Exercise the actual product UI with event/lifecycle modeling.
local P=dofile('lua/protocol.lua')
local objects,timer,timer_handle={},nil,nil
local lvgl={FLAG={SCROLLABLE=1,CLICKABLE=2,HIDDEN=3},EVENT={CLICKED=1,DELETE=2,SCREEN_UNLOADED=3,SCREEN_LOADED=4,PRESSED=5,PRESSING=6,RELEASED=7,PRESS_LOST=8},ALIGN={TOP_MID=1,TOP_LEFT=2,CENTER=3}}
local pointer_x,pointer_y=0,0
lvgl.indev={get_act=function()return {get_point=function()return pointer_x,pointer_y end}end}
function lvgl.HOR_RES()return 212 end
function lvgl.VER_RES()return 520 end
function lvgl.OPA(n)return n end
function lvgl.Font(_,size)return size end
local function object(parent,props,kind)
 local o={parent=parent,props=props,events={},flags={},kind=kind}
 function o:set(values)for k,v in pairs(values)do self.props[k]=v end end
 function o:clear_flag(flag)self.flags[flag]=nil end
 function o:add_flag(flag)self.flags[flag]=true end
 function o:onevent(event,fn)self.events[event]=fn end
 objects[#objects+1]=o;return o
end
function lvgl.Object(parent,props)return object(parent,props,'object')end
function lvgl.Label(parent,props)return object(parent,props,'label')end
function lvgl.Timer(props)
 timer=props;timer_handle={paused=false,deleted=false}
 function timer_handle:pause()self.paused=true end
 function timer_handle:resume()self.paused=false end
 function timer_handle:delete()self.deleted=true end
 return timer_handle
end
local s,starts,ticks,suspends,resumes,stops,changes=nil,0,0,0,0,0,0
local function new_session()
 s={phase='starting',closed=false,devices={},selected=1,desired={0,0},control_state='unknown',controls_ready=false}
 function s.tick()
  ticks=ticks+1
  if s.phase=='starting' or s.phase=='scan_stopping' then s.phase='idle'
  elseif s.phase=='connecting' then s.phase='ready';s.write_handle=5;s.battery=82
  elseif s.phase=='disconnecting' then s.phase='closed';s.closed=true;s.target=nil
  elseif s.control_state=='stopping' or s.control_state=='setting' then s.control_state='idle';s.controls_ready=true;s.confirmed={s.desired[1],s.desired[2]}end
 end
 function s.scan()s.phase='scanning' end
 function s.stop_scan()s.phase='scan_stopping' end
 function s.connect()s.phase='connecting';s.target=s.devices[s.selected]end
 function s.stop()stops=stops+1;s.desired={0,0};s.control_state='stopping'end
 function s.set_levels(a,b)changes=changes+1;s.desired={a,b};s.control_state='setting'end
 function s.disconnect()s.phase='disconnecting';s.controls_ready=false end
 function s.close()s.closed=true;s.phase='closed'end
 function s.suspend()suspends=suspends+1 end
 function s.resume()resumes=resumes+1 end
 return s
end
local env=setmetatable({Display=Display,P=P,require=function(name)assert(name=='lvgl');return lvgl end,
 io={open=function()return nil end},profile={target_id='test',image_crc=0},
 BLE={new=function()starts=starts+1;return {start=function(cb)cb('启动')end}end},Session={new=new_session}}, {__index=_G})
local function visible(o)return not o.flags[lvgl.FLAG.HIDDEN] and (not o.parent or visible(o.parent))end
local function find(value)
 for _,o in ipairs(objects)do if visible(o) and o.props.text==value then return o end end
end
local function click(value)
 local label=assert(find(value),'Missing visible label '..value)
 local target=label.events[lvgl.EVENT.CLICKED] and label or label.parent
 assert(target.events[lvgl.EVENT.CLICKED],'No handler '..value)()
end
local snapshots={}
local function snapshot(name)
 local items={}
 for _,o in ipairs(objects)do
  if o.parent==objects[1] and visible(o)then
   local a=o.props.align;local item={kind=o.kind,x=a.x_ofs,y=a.y_ofs,w=o.props.w,h=o.props.h,bg=o.props.bg_color,radius=o.props.radius}
   if o.kind=='label' then item.text=o.props.text;item.font=o.props.text_font;item.color=o.props.text_color
   else
    for _,child in ipairs(objects)do if child.parent==o then
     if child.kind=='label' then item.text=child.props.text;item.font=child.props.text_font;item.color=child.props.text_color
     else
      item.parts=item.parts or {};local c=child.props;local pos=c.align
      item.parts[#item.parts+1]={x=pos.x_ofs,y=pos.y_ofs,w=c.w,h=c.h,bg=c.bg_color,radius=c.radius}
     end
    end end
   end
   check(item.x>=0 and item.y>=0 and item.x+item.w<=212 and item.y+item.h<=520,'Bounds '..name)
   -- Every bounding-box corner must fit the physical capsule, inset by 8 px.
   -- Checking only rectangular screen bounds missed clipped end-cap controls.
   for _,x in ipairs({item.x,item.x+item.w})do
    for _,y in ipairs({item.y,item.y+item.h})do
     local cy=math.max(106,math.min(414,y))
     check((x-106)^2+(y-cy)^2<=98^2,'Capsule boundary '..name..' '..(item.text or 'slider'))
    end
   end
   if item.kind=='object' then check(item.h>=44,'Touch target '..name)end
   items[#items+1]=item
  end
 end
 for i,a in ipairs(items)do for j,b in ipairs(items)do
  if i<j then check(a.x+a.w<=b.x or b.x+b.w<=a.x or a.y+a.h<=b.y or b.y+b.h<=a.y,'Overlapping items '..name)end
 end end
 snapshots[#snapshots+1]={name=name,items=items}
end
assert(loadfile('lua/main.lua','t',env))()
check(find('连接') and find('帮助') and not find('迷路') and not find('设备遥控'))
local circle=find('连接').parent.props
check(circle.w==180 and circle.h==180 and circle.radius==90 and circle.align.x_ofs==16 and circle.align.y_ofs==170,'Centred circular connection button')
snapshot('首页');check(#snapshots[#snapshots].items==2,'Home contains only connect and help')
click('连接');timer.cb();check(s.phase=='scanning' and find('选择设备'))
snapshot('空设备列表')
s.devices={{name='Unknown',address='00:00:00:00:00:00'}}
for i=1,5 do s.devices[#s.devices+1]={name=i==1 and 'QCPW' or 'QCVW',address=string.format('01:02:03:04:05:%02X',i+5),raw='123456'}end
timer.cb();check(not find('Unknown'));snapshot('选择设备')
click('下一页');check(find('2 / 3'));click('下一页');check(find('3 / 3'));snapshot('设备末页');click('上一页');click('上一页');check(find('1 / 3'))
click('QCPW\n05:06');check(find('连接设备') and not s.closed);snapshot('连接中')
timer.cb();timer.cb();check(stops==1 and find('准备中'))
timer.cb();check(find('吮吸') and find('震动') and not find('＋ 10'))
snapshot('遥控首页')
local count=#objects
local lanes={}
for _,o in ipairs(objects)do if o.parent==objects[1] and o.events[lvgl.EVENT.PRESSED] then lanes[#lanes+1]=o end end
check(#lanes==2 and visible(lanes[1]) and visible(lanes[2]))
local function touch(i,event,y)
 pointer_x=lanes[i].props.align.x_ofs+32;pointer_y=y
 lanes[i].events[event]()
end
local function move(i,y)touch(i,lvgl.EVENT.PRESSING,y)end
-- Absolute positions map bottom=0, top=100; each lane preserves the other.
touch(1,lvgl.EVENT.PRESSED,320);move(1,306);move(1,292);move(1,277)
check(changes==3 and s.desired[1]==30 and s.desired[2]==0 and find('调整中'))
timer.cb();move(1,249);check(s.desired[1]==50,'Polling must not cancel an active drag')
touch(1,lvgl.EVENT.RELEASED,249);move(1,178);check(s.desired[1]==50,'Released drag ignores late movement')
touch(2,lvgl.EVENT.PRESSED,221);touch(2,lvgl.EVENT.RELEASED,221)
check(s.desired[1]==50 and s.desired[2]==70);timer.cb();snapshot('双通道调节')
touch(1,lvgl.EVENT.PRESSED,-20);check(s.desired[1]==100)
move(1,600);check(s.desired[1]==0 and s.desired[2]==70)
move(1,200);click('停止全部');check(stops==2 and find('停止中'))
local changed=changes;move(1,178);touch(2,lvgl.EVENT.PRESSED,178)
check(changes==changed and s.desired[1]==0 and s.desired[2]==0,'Stop blocks both sliders')
timer.cb();move(1,178);check(changes==changed,'Stop cancels the old finger gesture')
touch(2,lvgl.EVENT.PRESSED,306);touch(2,lvgl.EVENT.RELEASED,306);timer.cb();check(s.desired[2]==10)
click('‹ 返回');check(find('遥控') and not visible(lanes[1]) and not visible(lanes[2]))
click('遥控');check(visible(lanes[1]) and visible(lanes[2]) and find('10'))
click('设备');check(find('设备') and find('电量 82%'));snapshot('设备')
click('帮助');check(find('帮助'));snapshot('帮助连接');click('下一页');snapshot('帮助调节');click('下一页');snapshot('帮助熄屏');click('‹ 返回');check(find('设备'))
check(#objects==count and starts==1 and not s.closed,'Internal navigation must retain the same root and BLE session')
local before=ticks
env.ScreenStateChangedCB('ON','OFF');timer.cb()
check(timer_handle.paused and suspends==1 and ticks==before and not s.closed)
env.ScreenStateChangedCB('OFF','AOD');objects[1].events[lvgl.EVENT.SCREEN_UNLOADED]();objects[1].events[lvgl.EVENT.SCREEN_LOADED]()
check(suspends==1 and resumes==0 and timer_handle.paused)
env.ScreenStateChangedCB('AOD','ON');check(resumes==1 and not timer_handle.paused and find('设备'))
objects[1].events[lvgl.EVENT.SCREEN_UNLOADED]();env.ScreenStateChangedCB('ON','OFF');env.ScreenStateChangedCB('OFF','ON')
check(resumes==1 and timer_handle.paused)
objects[1].events[lvgl.EVENT.SCREEN_LOADED]();check(resumes==2 and not timer_handle.paused)
click('‹ 返回');touch(1,lvgl.EVENT.PRESSED,306);changed=changes
env.ScreenStateChangedCB('ON','OFF');env.ScreenStateChangedCB('OFF','ON');move(1,178)
check(changes==changed and s.desired[1]==10,'Wake must not continue the previous finger gesture')
touch(1,lvgl.EVENT.PRESSED,178);touch(1,lvgl.EVENT.PRESS_LOST,178);changed=changes;move(1,320)
check(changes==changed,'Lost capture cancels dragging')
click('设备')
click('断开连接');check(find('断开中'));timer.cb();check(s.closed and find('连接'))
click('连接');timer.cb();s.phase='failed';s.message='smash.lua:998: BLE op 11 failed 5';timer.cb()
check(find('设备未响应') and not find(s.message));snapshot('失败恢复')
objects[1].events[lvgl.EVENT.DELETE]();check(timer_handle.deleted and s.closed)
local resumed=resumes;env.ScreenStateChangedCB('OFF','ON');check(resumes==resumed)
if arg[1]then
 local function json(v)
  if type(v)=='string' then return '"'..v:gsub('\\','\\\\'):gsub('"','\\"'):gsub('\n','\\n'):gsub('\r','\\r')..'"'end
  if type(v)=='number' then return tostring(v)end
  local p={};if #v>0 then for _,x in ipairs(v)do p[#p+1]=json(x)end;return '['..table.concat(p,',')..']'end
  for k,x in pairs(v)do p[#p+1]=json(k)..':'..json(x)end;return '{'..table.concat(p,',')..'}'
 end
 local f=assert(io.open(arg[1],'w'));f:write(json(snapshots));f:close()
end
print('Product UI/display: '..tests..' assertions passed')

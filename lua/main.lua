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

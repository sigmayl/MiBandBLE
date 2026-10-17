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

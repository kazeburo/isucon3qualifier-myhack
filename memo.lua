local cjson = require "cjson"

function identity(str)
    return str
end

local base1 = [[
<!DOCTYPE html>
<html>
<head>
<meta http-equiv="Content-Type" content="text/html" charset="utf-8">
<title>Isucon3</title>
<link rel="stylesheet" href="/css/bootstrap.min.css">
<style>
body {
  padding-top: 60px;
}
</style>
<link rel="stylesheet" href="/css/bootstrap-responsive.min.css">
</head>
<body>
<div class="navbar navbar-fixed-top">
<div class="navbar-inner">
<div class="container">
<a class="btn btn-navbar" data-toggle="collapse" data-target=".nav-collapse">
<span class="icon-bar"></span>
<span class="icon-bar"></span>
<span class="icon-bar"></span>
</a>
<a class="brand" href="/">Isucon3</a>
<div class="nav-collapse">
<ul class="nav">
<li><a href="/">Home</a></li>
]]

local base2 = [[
</div> <!-- /container -->

<script type="text/javascript" src="/js/jquery.min.js"></script>
<script type="text/javascript" src="/js/bootstrap.min.js"></script>
</body>
</html>
]]

local memcached = require "resty.memcached"
local memc, err = memcached:new{ key_transform = { identity, identity }}
if not memc then
   ngx.log(ngx.ERR,"failed to instantiate memc: ", err)
   ngx.status = ngx.HTTP_INTERNAL_SERVER_ERROR
   return
end
memc:set_timeout(1000) -- 1 sec
local ok, err = memc:connect("127.0.0.1", 12345)
if not ok then
   ngx.log(ngx.ERR, "failed to connect: ", err)
   ngx.status = ngx.HTTP_INTERNAL_SERVER_ERROR
   return
end

local isucon_userid = ngx.var.isucon_userid
local isucon_token = ngx.var.isucon_token
local isucon_username = ngx.var.isucon_username

local memo, flags, err = memc:get("memo:"..ngx.var.isucon_memoid)
if memo == nil then
   ngx.log(ngx.ERR, "memo is nil")
   ngx.exit(ngx.HTTP_NOT_ALLOWED)
end 

local memo_t = cjson.decode(memo);

if tonumber(memo_t["is_private"]) == 1 then
    if not isucon_userid or tonumber(isucon_userid) ~= tonumber(memo_t["user"]) then
        ngx.exit(ngx.HTTP_NOT_FOUND)
    end
end

local memos
if tonumber(isucon_userid) == tonumber(memo_t["user"]) then
    memos, flags, err = memc:get("user_memos_all:"..memo_t["user"])
else
    memos, flags, err = memc:get("user_memos_public:"..memo_t["user"])
end

if memos == nil then 
   ngx.exit(405)
end 

local memos_t = cjson.decode(memos);
local older = 0
local newer = 0

for i, value in ipairs(memos_t) do
   if tonumber(value) == tonumber(memo_t["id"]) then
       if i > 1 then
           older = tonumber(memos_t[i-1])
       end
       if i < #memos_t  then
           newer = tonumber(memos_t[i+1])
       end
       break
   end
end
memc:set_keepalive(1000, 100)

local is_private = "Public\n"
if tonumber(memo_t["is_private"]) == 1 then
    is_private = "Private\n"
end

-- ngx.log(ngx.ERR, isucon_username,'==',string.len(isucon_username));
if string.len(isucon_username) > 0 then
   ngx.say(base1..'<li><a href="/mypage">MyPage</a></li><li><form action="/signout" method="post"><input type="hidden" name="sid" value="'..isucon_token..'"><input type="submit" value="SignOut"></form></li></ul></div> <!--/.nav-collapse --></div></div></div><div class="container"><h2>Hello '..isucon_username..'!</h2><p id="author">')
else
    ngx.say(base1..'<li><a href="/signin">SignIn</a></li></ul></div> <!--/.nav-collapse --></div></div></div><div class="container"><h2>Hello !</h2><p id="author">');
end

ngx.say(is_private..'Memo by '..memo_t["username"]..' ('..memo_t["created_at"]..')</p><hr>');

if older > 0 then
    ngx.say('<a id="older" href="http://'..ngx.var.http_host..'/memo/'..older..'">&lt; older memo</a>')
end
ngx.say('|')
if newer > 0 then
    ngx.say('<a id="newer" href="http://'..ngx.var.http_host..'/memo/'..newer..'">newer memo &gt;</a>')
end

ngx.say('<hr><div id="content_html">'..memo_t["content_html"]..'</div>'..base2)



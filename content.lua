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
   ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
end
memc:set_timeout(1000) -- 1 sec
local ok, err = memc:connect("127.0.0.1", 12345)
if not ok then
   ngx.log(ngx.ERR, "failed to connect: ", err)
   ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
end

local content, flags, err = memc:get("page:"..ngx.var.uri)
memc:set_keepalive(1000, 100)

local isucon_token = ngx.var.isucon_token
local isucon_username = ngx.var.isucon_username

-- ngx.log(ngx.ERR, isucon_username,'==',string.len(isucon_username));
if string.len(isucon_username) > 0 then
   ngx.say(base1..'<li><a href="/mypage">MyPage</a></li><li><form action="/signout" method="post"><input type="hidden" name="sid" value="'..isucon_token..'"><input type="submit" value="SignOut"></form></li></ul></div> <!--/.nav-collapse --></div></div></div><div class="container"><h2>Hello '..isucon_username..'!</h2>'..content..base2)
else 
    ngx.say(base1..'<li><a href="/signin">SignIn</a></li></ul></div> <!--/.nav-collapse --></div></div></div><div class="container"><h2>Hello !</h2>'..content..base2);
end




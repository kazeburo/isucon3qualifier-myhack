local t = split(ngx.var.cookie_isucon_session, ",")
if t[3] then
  ngx.var.isucon_user = t[2]
  ngx.var.isucon_token = t[3]
end


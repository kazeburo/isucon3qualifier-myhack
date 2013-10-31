if ngx.var.cookie_isucon_session then 
    local t = split(ngx.unescape_uri(ngx.var.cookie_isucon_session), ",")
    if t[2] then
        ngx.var.isucon_username = t[2]
        ngx.var.isucon_token = t[3]
    end
end

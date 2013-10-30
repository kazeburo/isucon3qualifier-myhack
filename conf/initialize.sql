alter table memos add column title text, add index memos_mypage(user), add index pager(user,is_private);
UPDATE memos SET title = substring_index(content,"\n",1);


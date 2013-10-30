alter table memos add column title text, add index memos_mypage(user);
UPDATE memos SET title = substring_index(content,"\n",1);


### P0 · 用户输入直接拼接进 SQL（L30–L31）
<!-- kiro-inline:c085dccf724503eb2191880c8452558081e9b9ef L30-31 sev=P0 -->

`q` 取自 `request.args` 未做任何处理就拼进 SQL 字符串，攻击者可用 `' OR 1=1--` 读取整表。第二句说明影响面。

**修复建议**

改用参数化查询：

```python
cur.execute("SELECT * FROM users WHERE name LIKE ?", (f"%{q}%",))
```

— Kiro 评审 · 提交 `90fcb05`

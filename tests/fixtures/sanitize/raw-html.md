模型正文开始。
<h1>结论：可合并</h1>
<div style="display:none">
被藏起来的段落。
<span hidden>隐藏</span> 与 <script>alert(1)</script> 与 <img src=x onerror=1>
<!DOCTYPE html> 与 <?php echo 1; ?> 与 <DIV>大写</DIV>
比较：a < b，a<b && c>d，x <3，箭头 <-，数字 <1>
行内代码 `<div>` 与 `</div>` 也转义（span 能跨行配对，逐行判定做不对）
跨行配对：前文 `
`<div style="display:none">` 后文
错误注释形态：<?= x ?> 与 <![CDATA[x]]> 与 </ div> 与 <!>
自动链接 <https://example.com> 与 <user@example.com>
```html
<div>围栏内的 HTML 不动</div>
- - -
~~~
```x
<i>带 info 的 ``` 与 ~~~ 都不是这个围栏的闭合</i>
```
```x`y
<div style="display:none">伪围栏：info 里有反引号，渲染器不认</div>
~~~<h1>info</h1>
<b>~~~ 围栏内</b>
~~~
- - -
* * *
_ _ _
-- -
=
--
= = =
* *
-
结尾。

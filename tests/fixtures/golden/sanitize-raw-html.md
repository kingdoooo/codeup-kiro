模型正文开始。
&lt;h1>结论：可合并&lt;/h1>
&lt;div style="display:none">
被藏起来的段落。
&lt;span hidden>隐藏&lt;/span> 与 &lt;script>alert(1)&lt;/script> 与 &lt;img src=x onerror=1>
&lt;!DOCTYPE html> 与 &lt;?php echo 1; ?> 与 &lt;DIV>大写&lt;/DIV>
比较：a < b，a&lt;b && c>d，x <3，箭头 <-，数字 <1>
行内代码 `&lt;div>` 与 `&lt;/div>` 也转义（span 能跨行配对，逐行判定做不对）
跨行配对：前文 `
`&lt;div style="display:none">` 后文
错误注释形态：&lt;?= x ?> 与 &lt;![CDATA[x]]> 与 &lt;/ div> 与 &lt;!>
自动链接 &lt;https://example.com> 与 &lt;user@example.com>
```html
<div>围栏内的 HTML 不动</div>
- - -
~~~
```x
<i>带 info 的 ``` 与 ~~~ 都不是这个围栏的闭合</i>
```
```x`y
&lt;div style="display:none">伪围栏：info 里有反引号，渲染器不认&lt;/div>
~~~&lt;h1>info&lt;/h1>
<b>~~~ 围栏内</b>
~~~
\- - -
\* * *
\_ _ _
\-- -
\=
\--
= = =
* *
\-
结尾。

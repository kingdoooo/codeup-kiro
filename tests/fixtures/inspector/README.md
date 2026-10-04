# Inspector fixture

来源：issue 01 的真实探测（2026-10-04，us-west-2，Amazon Inspector SBOM Generator 1.16.0）。被扫的是一棵**合成**测试树
（`py/requirements.txt`：PyYAML 5.3、requests 2.19.0；`mvn/pom.xml`：log4j-core 2.14.1；`npm/package-lock.json`：lodash 4.17.15），
不含任何真实仓库内容。

- `head.cdx.json`：sbomgen 输出，调用方式与生产相同——`setpriv --reuid=65534 --regid=65534 --clear-groups --no-new-privs`
  `env -i PATH=/usr/bin:/bin HOME=<私有目录>` `inspector-sbomgen directory --path /w/tree-prod -o … --skip-cloud-metadata`，
  在 `public.ecr.aws/docker/library/debian:stable-slim`、`--network none` 的容器里。
- `base.cdx.json`：同一棵树删掉 `requests` 那一行后再跑一次。
- `scan-response.json`：用 `head.cdx.json` 的原始版本调 `inspector-scan ScanSbom`（`outputFormat=CYCLONE_DX_1_5`）的完整响应
  （boto3 返回值按 JSON 原样落盘，只去掉 `ResponseMetadata`）。

唯一的变换（`.scratch/codeup-kiro-phase2b/probes/inspector/make-fixtures.sh`）= 生产上 `scan_sbomgen` 在上传前做的那一步：
组件路径属性去掉树根前缀（`/w/tree-prod/`、`/w/tree-base/`）、根组件名改成 `.`；响应里的 `amazon:inspector:sbom_scanner:path`
同样去掉前缀（探测时送的是未改写的 SBOM）。其它字节不动。

| 文件 | 原始 sha256 | fixture sha256 |
|---|---|---|
| head.cdx.json | `2c14ef1fa99f41bb42145efe937fa872753bdcb875064a3771188a04920b22fa` | `7c9f69f799fdce1719a30838df43988f89faeddbbbae22d200e928894fb569e8` |
| base.cdx.json | `9dc0253afef7a9ea10997270d42fe2624b9b7f7a8ddb660bf91c00ad69d98635` | `f7e674605c75d3255da3a59c4c24c29d387b5576101c4c7d0da96f7607cb89c7` |
| scan-response.json | `8fea2f2883eee3b6d02c27cea806f901aa665261675e577ccdcfc142646805fd` | `79244c42b76fd8e39df02f00b5c5cc3c9b87d9a0a15da7854d05af4260a66998` |

响应的 `metadata.properties` 计数（Inspector 自己的）：critical 5 · high 6 · medium 10 · low 0 · other 0；21 个漏洞、5 个组件。

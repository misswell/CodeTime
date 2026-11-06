排除模板的**可执行来源**位于：

`Packages/CodeTimeKit/Sources/BackupEngine/Resources/ExclusionPresets/default-presets.json`

它随 Swift Package 资源打包，并由 `ExclusionPresets.load()` 读取。此目录保留为
文档入口；修改模板请编辑上述 JSON，然后重新构建。

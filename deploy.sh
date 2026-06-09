#!/bin/bash

echo "🚀 开始部署 MkDocs..."

# 添加改动
git add .

# 提交（如果没有改动不会报错）
git commit -m "update: auto deploy" || echo "no changes to commit"

# 推送到 GitHub
git push origin main

echo "✅ 已推送到 GitHub，正在自动部署..."
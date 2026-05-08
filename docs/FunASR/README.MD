# 安装依赖
pip3 install onnxscript
pip3 install funasr_onnx -i https://mirror.sjtu.edu.cn/pypi/web/simple
pip3 install funasr_onnx websockets numpy -i https://mirror.sjtu.edu.cn/pypi/web/simple


# 卸载旧版本
pip3 uninstall funasr_onnx -y

# 安装官方 funasr
pip3 install funasr

# 或使用国内镜像
pip3 install funasr -i https://mirror.sjtu.edu.cn/pypi/web/simple
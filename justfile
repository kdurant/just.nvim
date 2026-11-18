# 创建C文件
cmd1:
        touch main.c

# 创建rust文件
cmd2:
        touch main.rs

# 带参数的命令
cmd3 context="nihao":
        echo {{context}}  > main.v
        sleep 5

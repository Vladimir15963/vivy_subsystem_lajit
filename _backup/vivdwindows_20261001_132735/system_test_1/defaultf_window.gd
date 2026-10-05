extends Window

var _dev_cache := {}


## 初始化窗口节点，args为添加窗口时传递的参数，详情请参考vivd_windows_node.gd
func _start(args):
    print(args)

func test(args):
    print("test通讯正常",args)

func fade_in():
    print("fade_in")
    pass
    
func fade_out(): 
    print("fade_out")
    pass

func _process(_delta):
    if has_meta("dev") and $dev/Control/devinfo and get_meta("dev"):
        for n in $dev/Control/devinfo.get_children():
            var value = get(n.name)
            if value == null:
                continue
            var cached = _dev_cache.get(n.name)
            if cached == value:
                continue
            _dev_cache[n.name] = value
            n.text = n.name + ": " + str(value)
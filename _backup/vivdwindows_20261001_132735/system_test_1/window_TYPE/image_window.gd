extends Window

## 图片窗口类型,用于显示图片的独立窗口
## 在_start方法中，接受的数组的第一个元素为图片路径


var _dev_cache := {}


## 初始化窗口节点，args为添加窗口时传递的参数，详情请参考vivd_windows_node.gd
func _start(args:Array):
    if args.size() == 0:
        return
    var image_path = args[0]
    var image = load(image_path)
    if image == null:
        return
    
    $Control/TextureRect.texture = image
    print(image_path)

func test(args:Array):
    print("调用test通讯正常",args)

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

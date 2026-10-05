extends Window

var _dev_cache := {}


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

func _ready():
    
    get_window().files_dropped.connect(_on_file_drop)

func _on_file_drop(files):
    for f in files:
        print(f)
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

extends Node
## 这个为多窗口动态演示的系统，它被全局加载在场景中，用于管理所有的子窗口，以实现多窗口的动态变化
## 为剧本开发提供高级的窗口管理功能，如添加、删除、切换窗口等，模板化使用
## 可以自定义不同的窗口节点
## w表示窗口节点

## 窗口类型字典，键为窗口类型名称，值为窗口场景,用于创建窗口节点
@export var window_type :Dictionary[String,PackedScene]={}


var windows : Dictionary[String,Window] = {}
var is_dev : bool = false

func set_dev(dev : bool):
    is_dev = dev
    print("set_dev ", dev)


## 添加一个名为_name的窗口，标题为title，类型为type_name
func add_window(_name : String,title : String,type_name :String,...args):


    if type_name in window_type:
        var w = window_type[type_name].instantiate()
        w.title = title
        if is_dev:
            w.set_meta("dev",true)
        else:
            w.set_meta("dev",false)
        w.name = _name
        add_child(w)
        ## 调用窗口节点的初始化方法
        w._start(args)
        windows[_name] = w
    else:
        print("window_type not found")


## 删除窗口,不进行任何过度效果
func remove_window(_name : String):
    if _name in windows:
        windows.erase(_name)
        remove_child(windows[_name])


## 以3次方插值的方式移动窗口
func move_window(_name : String,position : Vector2i):
    var w = windows.get(_name)
    if w:
        ## 以3次方插值的方式移动窗口
        var tween = create_tween()
        tween.set_trans(Tween.TRANS_CUBIC)
        tween.tween_property(w,"position",position,0.5)

## 调整窗口大小
func resize_window(_name : String,size : Vector2i):
    var w = windows.get(_name)
    if w:
        ## 以3次方插值的方式调整窗口大小
        var tween = create_tween()
        tween.set_trans(Tween.TRANS_CUBIC)
        tween.tween_property(w,"size",size,0.5)
    else:
        print("window not found")

func _ready():
    print("VivdWindowsNode ready")
    print(window_type)
    if "defaultf" in window_type:
        print("defaultf_window found")
    else:
        print("defaultf_window not found")

## 调用窗口节点的方法
func call_window_method(_name : String,method : String,...args):
    var w = windows.get(_name)
    if w:
        w.call(method,args)
    else:
        print("window not found")

## 以默认的方式切入窗口
func fade_window_in(_name : String):
    var w = windows.get(_name)
    if w:
        w.fade_in()
    else:
        print("window not found")

## 以默认的方式切出窗口
func fade_window_out(_name : String):
    var w = windows.get(_name)
    if w:
        w.fade_out()
    else:
        print("window not found")

#region
## 窗口类型相关的方法

## 注册窗口类型，键为窗口类型名称，需已经加载窗口场景
## 用于创建窗口节点
func register_window_type(type_name : String,scene : PackedScene):
    window_type[type_name] = scene
    print("register_window_type ",type_name)

## 获取窗口类型
func get_window_type(type_name : String):
    return window_type.get(type_name)

## 注销窗口类型，
func unregister_window_type(type_name : String):
    window_type.erase(type_name)
    print("unregister_window_type ",type_name)
#endregion
## Interface idioms/patterns in zig standard libraries ##

### introduction ###
In zig, you can declare functions in struct, enum, union and opaque. Functions whose 1st argument has type of its containing struct/enum/union/opaque are methods which can be invoked through dot syntax. Java and Go support "interface" for creating abstractions with a group of methods (or method-set). Normally interfaces hold so-called vtable for dynamic dispatching. Although zig doesn't support interface as a language feature yet, its standard libraries apply a few code idioms or patterns to achieve similar effects. 

Similar to other languages, zig code idiom and patterns enable:
* type checking instance/object methods against interface types at compile time,
* dynamic dispatching at runtime.

There are some notable differences:
* Go's interfaces are independent from the types/instances they abstract over. Interfaces can be added at any time when common patterns of api/methods are observed across diverse types. There is no need going back to change types for implementing new interfaces, that is required for Java.
* Go's interfaces contain only vtab for dynamic dispatching and small method-set/vtable are preferred, eg. io.Reader and io.Writer with single method. Common utilities such as io.Copy, CopyN, ReadFull, ReadAtLeast are provided as package functions using those small interfaces. Zig's interfaces, such as std.mem.Allocator, typically contains both vtable and common utilities as methods; so they normally have many methods.

The following are study notes of zig's code idioms/patterns for dynamic dispatching, with code extracts from zig standard libraries. To focus on vtab/dynamic dispatching, utility methods are removed and code are modified a bit to fit Go's model of small interfaces independent from concrete types.

Full code is located in this [repo](https://github.com/yglcode/zig_interfaces) and you can run it with "zig test interfaces.zig".

### set up ###
Let's use the classical OOP example, create a few shapes: Point, Box and Circle.

```zig
const Point = struct {
    x: i32 = 0,
    y: i32 = 0,
    pub fn move(self: *Point, dx: i32, dy: i32) void {
        self.x += dx;
        self.y += dy;
    }
    pub fn draw(self: *Point) void {
        print("point@<{d},{d}>\n", .{ self.x, self.y });
    }
};

const Box = struct {
    p1: Point,
    p2: Point,
    pub fn init(p1: Point, p2: Point) Box {
        return .{ .p1 = p1, .p2 = p2 };
    }
    pub fn move(self: *Box, dx: i32, dy: i32) void {
        ......
    }
    pub fn draw(self: *Box) void {
        ......
    }
};

const Circle = struct {
    center: Point,
    radius: i32,
    pub fn init(c: Point, r: i32) Circle {
        return .{ .center = c, .radius = r };
    }
    pub fn move(self: *Circle, dx: i32, dy: i32) void {
        self.center.move(dx, dy);
    }
    pub fn draw(self: *Circle) void {
        ......
    }
};

//create a set of "shapes" for test
fn init_data() struct { point: Point, box: Box, circle: Circle } {
    return .{
        .point = Point{},
        .box = Box.init(Point{}, Point{ .x = 2, .y = 3 }),
        .circle = Circle.init(Point{}, 5),
    };
}
```
### interface 1: enum tagged union ###
Using enum tagged union for interfaces is introduced by Loris Cro ["Easy Interfaces with zig 0.10.0"](https://zig.news/kristoff/easy-interfaces-with-zig-0100-2hc5). This is the simplest solution, although you have to explicitly list, in the union, all the variant types which "implement" the interface.
``` zig
const Shape1 = union(enum) {
    point: *Point,
    box: *Box,
    circle: *Circle,
    pub fn move(self: Shape1, dx: i32, dy: i32) void {
        switch (self) {
            inline else => |s| s.move(dx, dy),
        }
    }
    pub fn draw(self: Shape1) void {
        switch (self) {
            inline else => |s| s.draw(),
        }
    }
};
```
We can test it as following:

``` zig
test "union_as_intf" {
    var data = init_data();
    var shapes = [_]Shape1{
        .{ .point = &data.point },
        .{ .box = &data.box },
        .{ .circle = &data.circle },
    };
    for (shapes) |s| {
        s.move(11, 22);
        s.draw();
    }
}
```
### interface 2: 1st implementation of vtable and dynamic disptaching ###
Zig has switched from old style dynamic dispatching based on embedded vtab and #fieldParentPtr(), to the following pattern based on "fat pointer" interface; please go to this article for more details ["Allocgate is coming in Zig 0.9,..."](https://pithlessly.github.io/allocgate.html). 

Interface std.mem.Allocator uses this pattern, and all standard allocators, std.heap.[ArenaAllocator, GeneralPurposeAllocator, ...] have a method "allocator() Allocator" to expose this interface. The following code changed a bit to douple the interface from implementations.

``` zig
const Shape2 = struct {
    // define interface fields: ptr,vtab
    ptr: *anyopaque, //ptr to instance
    vtab: *const VTab, //ptr to vtab
    const VTab = struct {
        draw: *const fn (ptr: *anyopaque) void,
        move: *const fn (ptr: *anyopaque, dx: i32, dy: i32) void,
    };

    // define interface methods wrapping vtable calls
    pub fn draw(self: Shape2) void {
        self.vtab.draw(self.ptr);
    }
    pub fn move(self: Shape2, dx: i32, dy: i32) void {
        self.vtab.move(self.ptr, dx, dy);
    }

    // cast concrete implementation types/objs to interface
    pub fn init(obj: anytype) Shape2 {
        const Ptr = @TypeOf(obj);
        const PtrInfo = @typeInfo(Ptr);
        assert(PtrInfo == .Pointer); // Must be a pointer
        assert(PtrInfo.Pointer.size == .One); // Must be a single-item pointer
        assert(@typeInfo(PtrInfo.Pointer.child) == .Struct); // Must point to a struct
        const alignment = PtrInfo.Pointer.alignment;
        const impl = struct {
            fn draw(ptr: *anyopaque) void {
                const self = @ptrCast(Ptr, @alignCast(alignment, ptr));
                self.draw();
            }
            fn move(ptr: *anyopaque, dx: i32, dy: i32) void {
                const self = @ptrCast(Ptr, @alignCast(alignment, ptr));
                self.move(dx, dy);
            }
        };
        return .{
            .ptr = obj,
            .vtab = &.{
                .draw = impl.draw,
                .move = impl.move,
            },
        };
    }
};
```
We can test it as following:

``` zig
test "vtab1_as_intf" {
    var data = init_data();
    var shapes = [_]Shape2{
        Shape2.init(&data.point),
        Shape2.init(&data.box),
        Shape2.init(&data.circle),
    };
    for (shapes) |s| {
        s.move(11, 22);
        s.draw();
    }
}
```
### interface 3: 2nd implementation of vtab and dynamic dispatch ###
In above 1st implementation, when "casting" a Box into interface Shape2 thru Shape2.init(), the box instance is type-checked for implementing the methods of Shape2 (matching signatures including names). There are two changes in the 2nd implementation: 
* the vtable is inlined in the interface struct (possible minus point, interface size increased).
* methods to be type checked against interface are explicitly passed in as function pointers, that possiblely enable the use case of passing in different methods, as long as they have same arguments/return types. For examples, if Box has extra methods, stopAt(i32,i32) or even scale(i32,i32), we can pass them in place of move().

Interface std.rand.Random and all std.rand.[Pcg, Sfc64, ...] use this pattern.
``` zig
const Shape3 = struct {
    // define interface fields: ptr,vtab
    // ptr to instance
    ptr: *anyopaque,
    // inline vtable
    drawFnPtr: *const fn (ptr: *anyopaque) void,
    moveFnPtr: *const fn (ptr: *anyopaque, dx: i32, dy: i32) void,

    pub fn init(
        obj: anytype,
        comptime drawFn: fn (ptr: @TypeOf(obj)) void,
        comptime moveFn: fn (ptr: @TypeOf(obj), dx: i32, dy: i32) void,
    ) Shape3 {
        const Ptr = @TypeOf(obj);
        assert(@typeInfo(Ptr) == .Pointer); // Must be a pointer
        assert(@typeInfo(Ptr).Pointer.size == .One); // Must be a single-item pointer
        assert(@typeInfo(@typeInfo(Ptr).Pointer.child) == .Struct); // Must point to a struct
        const alignment = @typeInfo(Ptr).Pointer.alignment;
        const impl = struct {
            fn draw(ptr: *anyopaque) void {
                const self = @ptrCast(Ptr, @alignCast(alignment, ptr));
                drawFn(self);
            }
            fn move(ptr: *anyopaque, dx: i32, dy: i32) void {
                const self = @ptrCast(Ptr, @alignCast(alignment, ptr));
                moveFn(self, dx, dy);
            }
        };

        return .{
            .ptr = obj,
            .drawFnPtr = impl.draw,
            .moveFnPtr = impl.move,
        };
    }

    // define interface methods wrapping vtable func-ptrs
    pub fn draw(self: Shape3) void {
        self.drawFnPtr(self.ptr);
    }
    pub fn move(self: Shape3, dx: i32, dy: i32) void {
        self.moveFnPtr(self.ptr, dx, dy);
    }
};
```
We can test it as following:
``` zig
test "vtab2_as_intf" {
    var data = init_data();
    var shapes = [_]Shape3{
        Shape3.init(&data.point, Point.draw, Point.move),
        Shape3.init(&data.box, Box.draw, Box.move),
        Shape3.init(&data.circle, Circle.draw, Circle.move),
    };
    for (shapes) |s| {
        s.move(11, 22);
        s.draw();
    }
}
```
### interface 4: old style dynamic dispatch using embedded vtab and @fieldParentPtr() ###
Interface std.build.Step and all build steps std.build.[RunStep, FmtStep, ...] still use this pattern.

``` zig
// define interface/vtab
const Shape4 = struct {
    drawFn: *const fn (ptr: *Shape4) void,
    moveFn: *const fn (ptr: *Shape4, dx: i32, dy: i32) void,
    // define interface methods wrapping vtab funcs
    pub fn draw(self: *Shape4) void {
        self.drawFn(self);
    }
    pub fn move(self: *Shape4, dx: i32, dy: i32) void {
        self.moveFn(self, dx, dy);
    }
};
// embed vtab and define vtab funcs as wrappers over methods
const Circle4 = struct {
    center: Point,
    radius: i32,
    shape: Shape4,
    pub fn init(c: Point, r: i32) Circle4 {
        // define interface wrapper funcs
        const impl = struct {
            pub fn draw(ptr: *Shape4) void {
                const self = @fieldParentPtr(Circle4, "shape", ptr);
                self.draw();
            }
            pub fn move(ptr: *Shape4, dx: i32, dy: i32) void {
                const self = @fieldParentPtr(Circle4, "shape", ptr);
                self.move(dx, dy);
            }
        };
        return .{
            .center = c,
            .radius = r,
            .shape = .{ .moveFn = impl.move, .drawFn = impl.draw },
        };
    }
    // the following are methods
    pub fn move(self: *Circle4, dx: i32, dy: i32) void {
        self.center.move(dx, dy);
    }
    pub fn draw(self: *Circle4) void {
        print("circle@<{d},{d}>radius:{d}\n", .{ self.center.x, self.center.y, self.radius });
    }
};
// embed vtab and define vtab funcs on struct directly
const Box4 = struct {
    p1: Point,
    p2: Point,
    shape: Shape4,
    pub fn init(p1: Point, p2: Point) Box4 {
        return .{
            .p1 = p1,
            .p2 = p2,
            .shape = .{ .moveFn = move, .drawFn = draw },
        };
    }
    //the following are vtab funcs, not methods
    pub fn move(ptr: *Shape4, dx: i32, dy: i32) void {
        const self = @fieldParentPtr(Box4, "shape", ptr);
        self.p1.move(dx, dy);
        self.p2.move(dx, dy);
    }
    pub fn draw(ptr: *Shape4) void {
        const self = @fieldParentPtr(Box4, "shape", ptr);
        print("box@<{d},{d}>-<{d},{d}>\n", .{ self.p1.x, self.p1.y, self.p2.x, self.p2.y });
    }
};
```
We can test it as following:
``` zig
test "vtab3_embedded_in_struct" {
    var box = Box4.init(Point{}, Point{ .x = 2, .y = 3 });
    var circle = Circle4.init(Point{}, 5);

    var shapes = [_]*Shape4{
        &box.shape,
        &circle.shape,
    };
    for (shapes) |s| {
        s.move(11, 22);
        s.draw();
    }
}
```
### interface 5: generic interface at compile time ###
All above interfaces focus on vtab and dynamic dispatching: the interface values will hide the types of concrete values it holds. So you can put these interfaces values into an array and handle them uniformly.

With zig's compile-time computation, you can define generic algorithms which can work with any type which provides the methods or operators required by the code in function body. For example, we can define a generic algorithm:

``` zig
fn update_graphics(shape: anytype, dx: i32, dy: i32) void {
    shape.move(dx, dy);
    shape.draw();
}
```
As shown above, "shape" can be anytype as long as it provides move() and draw() methods. All type checking happen at comptime and no dynamic dispatching.

As following, we can define a generic interface which capture the methods required by some generic algorithm; and we can use it to adapt some types/instances with different method names into the required api.

Interface std.io.[Reader, Writer] and std.fifo and std.fs.File use this pattern.

Since these generic interfaces do not erase the type info of the values it hold, they are different types. Thus you cannot put them into an array for handling uniformally.

``` zig
pub fn Shape5(
    comptime Pointer: type,
    comptime drawFn: *const fn (ptr: Pointer) void,
    comptime moveFn: *const fn (ptr: Pointer, dx: i32, dy: i32) void,
) type {
    return struct {
        ptr: Pointer,
        const Self = @This();
        pub fn init(p: Pointer) Self {
            return .{ .ptr = p };
        }
        // interface methods wrapping passed-in funcs/methods
        pub fn draw(self: Self) void {
            drawFn(self.ptr);
        }
        pub fn move(self: Self, dx: i32, dy: i32) void {
            moveFn(self.ptr, dx, dy);
        }
    };
}

//a generic algorithms use duck-typing/static dispatch.
//note: shape can be "anytype" which provides move()/draw()
fn update_graphics(shape: anytype, dx: i32, dy: i32) void {
    shape.move(dx, dy);
    shape.draw();
}

//define a TextArea with similar but diff methods
const TextArea = struct {
    position: Point,
    text: []const u8,
    pub fn init(pos: Point, txt: []const u8) TextArea {
        return .{ .position = pos, .text = txt };
    }
    pub fn relocate(self: *TextArea, dx: i32, dy: i32) void {
        self.position.move(dx, dy);
    }
    pub fn display(self: *TextArea) void {
        print("text@<{d},{d}>:{s}\n", .{ self.position.x, self.position.y, self.text });
    }
};
```
We can test it as following:

``` zig
test "generic_interface" {
    var box = Box.init(Point{}, Point{ .x = 2, .y = 3 });
    //apply generic algorithms to matching types directly
    update_graphics(&box, 11, 22);
    var textarea = TextArea.init(Point{}, "hello zig!");
    //use generic interface to adapt non-matching types
    var drawText = Shape5(*TextArea, TextArea.display, TextArea.relocate).init(&textarea);
    update_graphics(drawText, 4, 5);
}
```

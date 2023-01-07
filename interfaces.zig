const std = @import("std");
const assert = std.debug.assert;
const print = std.debug.print;

//--- define a few "shapes": point, box, circle ---
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
        self.p1.move(dx, dy);
        self.p2.move(dx, dy);
    }
    pub fn draw(self: *Box) void {
        print("box@<{d},{d}>-<{d},{d}>\n", .{ self.p1.x, self.p1.y, self.p2.x, self.p2.y });
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
        print("circle@<{d},{d}>radius:{d}\n", .{ self.center.x, self.center.y, self.radius });
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

//--- interface1: enum tagged union ---
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

test "union_as_intf" {
    var data = init_data();
    var shapes = [_]Shape1{
        .{ .point = &data.point },
        .{ .box = &data.box },
        .{ .circle = &data.circle },
    };
    print("\n", .{});
    for (shapes) |s| {
        s.move(11, 22);
        s.draw();
    }
}

//--- interface2: 1st variant of vtable ---
// std.mem.Allocator works this way
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

    // cast concrete objects/types to interface
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

test "vtab1_as_intf" {
    var data = init_data();
    var shapes = [_]Shape2{
        Shape2.init(&data.point),
        Shape2.init(&data.box),
        Shape2.init(&data.circle),
    };
    print("\n", .{});
    for (shapes) |s| {
        s.move(11, 22);
        s.draw();
    }
}

//--- interface3: 2nd variant of vtable ---
// std.rand.Random works this way;
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

test "vtab2_as_intf" {
    var data = init_data();
    var shapes = [_]Shape3{
        Shape3.init(&data.point, Point.draw, Point.move),
        Shape3.init(&data.box, Box.draw, Box.move),
        Shape3.init(&data.circle, Circle.draw, Circle.move),
    };
    print("\n", .{});
    for (shapes) |s| {
        s.move(11, 22);
        s.draw();
    }
}

//--- interface4: embed vtab in concrete types ---
// std.build.Step works this way
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

test "vtab3_embedded_in_struct" {
    var box = Box4.init(Point{}, Point{ .x = 2, .y = 3 });
    var circle = Circle4.init(Point{}, 5);

    var shapes = [_]*Shape4{
        &box.shape,
        &circle.shape,
    };
    print("\n", .{});
    for (shapes) |s| {
        s.move(11, 22);
        s.draw();
    }
}

//--- interface5: generic interface at compile time ---
// api/method-set adaptor: wrap obj methods to a method-set
// required by generic algorithms, static dispatch (generics)
// std.io.(Reader/Writer) work this way
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

test "generic_interface" {
    var box = Box.init(Point{}, Point{ .x = 2, .y = 3 });
    print("\n", .{});
    //apply generic algorithms to matching types directly
    update_graphics(&box, 11, 22);
    var textarea = TextArea.init(Point{}, "hello zig!");
    //use generic interface to adapt non-matching types
    var drawText = Shape5(*TextArea, TextArea.display, TextArea.relocate).init(&textarea);
    update_graphics(drawText, 4, 5);
}

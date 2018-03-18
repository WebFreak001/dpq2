///
module dpq2.conv.geometric;

import dpq2.oids: OidType;
import dpq2.value: ConvExceptionType, throwTypeComplaint, Value, ValueConvException, ValueFormat;
import std.bitmanip: bigEndianToNative, nativeToBigEndian;
import std.traits;
import std.range.primitives: ElementType;

@safe:

private template GetRvalueOfMember(T, string memberName)
{
    mixin("alias MemberType = typeof(T."~memberName~");");

    static if(is(MemberType == function))
        alias R = ReturnType!(MemberType);
    else
        alias R = MemberType;

    alias GetRvalueOfMember = R;
}

/// Checks that type have "x" and "y" members of returning type "double"
bool isValidPointType(T)()
{
    static if(__traits(compiles, typeof(T.x)) && __traits(compiles, typeof(T.y)))
    {
        return
            is(GetRvalueOfMember!(T, "x") == double) &&
            is(GetRvalueOfMember!(T, "y") == double);
    }
    else
        return false;
}

/// Checks that type have "min" and "max" members of suitable returning type of point
bool isValidBoxType(T)()
{
    static if(__traits(compiles, typeof(T.min)) && __traits(compiles, typeof(T.max)))
    {
        return
            isValidPointType!(GetRvalueOfMember!(T, "min")) &&
            isValidPointType!(GetRvalueOfMember!(T, "max"));
    }
    else
        return false;
}

///
bool isValidLineSegmentType(T)()
{
    static if(__traits(compiles, typeof(T.start)) && __traits(compiles, typeof(T.end)))
    {
        return
            isValidPointType!(GetRvalueOfMember!(T, "start")) &&
            isValidPointType!(GetRvalueOfMember!(T, "end"));
    }
    else
        return false;
}

///
bool isValidPolygon(T)()
{
    return isArray!T && isValidPointType!(ElementType!T);
}

private auto serializePoint(Vec2Ddouble, T)(Vec2Ddouble point, T target)
if(isValidPointType!Vec2Ddouble)
{
    import std.algorithm : copy;

    auto rem = point.x.nativeToBigEndian.copy(target);
    rem = point.y.nativeToBigEndian.copy(rem);

    return rem;
}

Value toValue(Vec2Ddouble)(Vec2Ddouble pt)
if(isValidPointType!Vec2Ddouble)
{
    ubyte[] data = new ubyte[16];
    pt.serializePoint(data);

    return createValue(data, OidType.Point);
}

private auto serializeBox(Box, T)(Box box, T target)
{
    auto rem = box.max.serializePoint(target);
    rem = box.min.serializePoint(rem);

    return rem;
}

Value toValue(Box)(Box box)
if(isValidBoxType!Box)
{
    ubyte[] data = new ubyte[32];
    box.serializeBox(data);

    return createValue(data, OidType.Box);
}

/// Infinite line - {A,B,C} (Ax + By + C = 0)
struct Line
{
    double a; ///
    double b; ///
    double c; ///
}

///
struct Path(Point)
if(isValidPointType!Point)
{
    bool isClosed; ///
    Point[] points; ///
}

///
struct Circle(Point)
if(isValidPointType!Point)
{
    Point center; ///
    double radius; ///
}

Value toValue(T)(T line)
if(is(T == Line))
{
    import std.algorithm : copy;

    ubyte[] data = new ubyte[24];

    auto rem = line.a.nativeToBigEndian.copy(data);
    rem = line.b.nativeToBigEndian.copy(rem);
    rem = line.c.nativeToBigEndian.copy(rem);

    return createValue(data, OidType.Line);
}

Value toValue(LineSegment)(LineSegment lseg)
if(isValidLineSegmentType!LineSegment)
{
    ubyte[] data = new ubyte[32];

    auto rem = lseg.start.serializePoint(data);
    rem = lseg.end.serializePoint(rem);

    return createValue(data, OidType.LineSegment);
}

Value toValue(T)(T path)
if(isInstanceOf!(Path, T))
{
    import std.algorithm : copy;

    if(path.points.length < 1)
        throw new ValueConvException(ConvExceptionType.SIZE_MISMATCH,
            "At least one point is needed for Path", __FILE__, __LINE__);

    ubyte[] data = new ubyte[path.points.length * 16 + 5];

    auto rem = (cast(ubyte)(path.isClosed ? 1 : 0)).nativeToBigEndian.copy(data);
    rem = (cast(int)path.points.length).nativeToBigEndian.copy(rem);

    foreach (ref p; path.points)
    {
        rem = p.serializePoint(rem);
    }

    return createValue(data, OidType.Path);
}

Value toValue(Polygon)(Polygon poly)
if(isValidPolygon!Polygon)
{
    import std.algorithm : copy;

    if(poly.length < 1)
        throw new ValueConvException(ConvExceptionType.SIZE_MISMATCH,
            "At least one point is needed for Polygon", __FILE__, __LINE__);

    ubyte[] data = new ubyte[poly.length * 16 + 4];
    auto rem = (cast(int)poly.length).nativeToBigEndian.copy(data);

    foreach (ref p; poly)
        rem = p.serializePoint(rem);

    return createValue(data, OidType.Polygon);
}

Value toValue(T)(T c)
if(isInstanceOf!(Circle, T))
{
    import std.algorithm : copy;

    ubyte[] data = new ubyte[24];
    auto rem = c.center.serializePoint(data);
    c.radius.nativeToBigEndian.copy(rem);

    return createValue(data, OidType.Circle);
}

/// Caller must ensure that reference to the data will not be passed to elsewhere
private Value createValue(const ubyte[] data, OidType oid) pure @trusted
{
    return Value(cast(immutable) data, oid);
}

private alias AE = ValueConvException;
private alias ET = ConvExceptionType;

/// Convert to Point
Vec2Ddouble binaryValueAs(Vec2Ddouble)(in Value v)
if(isValidPointType!Vec2Ddouble)
{
    if(!(v.oidType == OidType.Point))
        throwTypeComplaint(v.oidType, "Point", __FILE__, __LINE__);

    auto data = v.data;

    if(!(data.length == 16))
        throw new AE(ET.SIZE_MISMATCH,
            "Value length isn't equal to Postgres Point size", __FILE__, __LINE__);

    return pointFromBytes!Vec2Ddouble(data[0..16]);
}

private Vec2Ddouble pointFromBytes(Vec2Ddouble)(in ubyte[16] data) pure
if(isValidPointType!Vec2Ddouble)
{
    return Vec2Ddouble(data[0..8].bigEndianToNative!double, data[8..16].bigEndianToNative!double);
}

T binaryValueAs(T)(in Value v)
if (is(T == Line))
{
    if(!(v.oidType == OidType.Line))
        throwTypeComplaint(v.oidType, "Line", __FILE__, __LINE__);

    if(!(v.data.length == 24))
        throw new AE(ET.SIZE_MISMATCH,
            "Value length isn't equal to Postgres Line size", __FILE__, __LINE__);

    return Line((v.data[0..8].bigEndianToNative!double), v.data[8..16].bigEndianToNative!double, v.data[16..24].bigEndianToNative!double);
}

LineSegment binaryValueAs(LineSegment)(in Value v)
if(isValidLineSegmentType!LineSegment)
{
    if(!(v.oidType == OidType.LineSegment))
        throwTypeComplaint(v.oidType, "LineSegment", __FILE__, __LINE__);

    if(!(v.data.length == 32))
        throw new AE(ET.SIZE_MISMATCH,
            "Value length isn't equal to Postgres LineSegment size", __FILE__, __LINE__);

    alias Point = ReturnType!(LineSegment.start);

    auto start = v.data[0..16].pointFromBytes!Point;
    auto end = v.data[16..32].pointFromBytes!Point;

    return LineSegment(start, end);
}

Box binaryValueAs(Box)(in Value v)
if(isValidBoxType!Box)
{
    if(!(v.oidType == OidType.Box))
        throwTypeComplaint(v.oidType, "Box", __FILE__, __LINE__);

    if(!(v.data.length == 32))
        throw new AE(ET.SIZE_MISMATCH,
            "Value length isn't equal to Postgres Box size", __FILE__, __LINE__);

    alias Point = typeof(Box.min);

    Box res;
    res.max = v.data[0..16].pointFromBytes!Point;
    res.min = v.data[16..32].pointFromBytes!Point;

    return res;
}

T binaryValueAs(T)(in Value v)
if(isInstanceOf!(Path, T))
{
    import std.array : uninitializedArray;

    if(!(v.oidType == OidType.Path))
        throwTypeComplaint(v.oidType, "Path", __FILE__, __LINE__);

    if(!((v.data.length - 5) % 16 == 0))
        throw new AE(ET.SIZE_MISMATCH,
            "Value length isn't equal to Postgres Path size", __FILE__, __LINE__);

    T res;
    res.isClosed = v.data[0..1].bigEndianToNative!byte == 1;
    int len = v.data[1..5].bigEndianToNative!int;

    if (len != (v.data.length - 5)/16)
        throw new AE(ET.SIZE_MISMATCH, "Path points number mismatch", __FILE__, __LINE__);

    alias Point = typeof(T.points[0]);

    res.points = uninitializedArray!(Point[])(len);
    for (int i=0; i<len; i++)
    {
        const ubyte[] b = v.data[ i*16+5 .. i*16+5+16 ];
        res.points[i] = b[0..16].pointFromBytes!Point;
    }

    return res;
}

Polygon binaryValueAs(Polygon)(in Value v)
if(isValidPolygon!Polygon)
{
    import std.array : uninitializedArray;

    if(!(v.oidType == OidType.Polygon))
        throwTypeComplaint(v.oidType, "Polygon", __FILE__, __LINE__);

    if(!((v.data.length - 4) % 16 == 0))
        throw new AE(ET.SIZE_MISMATCH,
            "Value length isn't equal to Postgres Polygon size", __FILE__, __LINE__);

    Polygon res;
    int len = v.data[0..4].bigEndianToNative!int;

    if (len != (v.data.length - 4)/16)
        throw new AE(ET.SIZE_MISMATCH, "Path points number mismatch", __FILE__, __LINE__);

    alias Point = ElementType!Polygon;

    res = uninitializedArray!(Point[])(len);
    for (int i=0; i<len; i++)
    {
        const ubyte[] b = v.data[(i*16+4)..(i*16+16+4)];
        res[i] = b[0..16].pointFromBytes!Point;
    }

    return res;
}

T binaryValueAs(T)(in Value v)
if(isInstanceOf!(Circle, T))
{
    if(!(v.oidType == OidType.Circle))
        throwTypeComplaint(v.oidType, "Circle", __FILE__, __LINE__);

    if(!(v.data.length == 24))
        throw new AE(ET.SIZE_MISMATCH,
            "Value length isn't equal to Postgres Circle size", __FILE__, __LINE__);

    alias Point = typeof(T.center);

    return T(
        v.data[0..16].pointFromBytes!Point,
        v.data[16..24].bigEndianToNative!double
    );
}

version (integration_tests)
package mixin template GeometricInstancesForIntegrationTest()
{
    @safe:

    import gfm.math;
    import dpq2.conv.geometric: Circle, Path;

    alias Point = vec2d;
    alias Box = box2d;
    static struct LineSegment
    {
        seg2d seg;
        alias seg this;

        ref Point start(){ return a; }
        ref Point end(){ return b; }

        this(Point a, Point b)
        {
            seg.a = a;
            seg.b = b;
        }
    }
    alias TestPath = Path!Point;
    alias Polygon = Point[];
    alias TestCircle = Circle!Point;
}

version (integration_tests)
unittest
{
    mixin GeometricInstancesForIntegrationTest;

    // binary write/read
    {
        auto pt = Point(1,2);
        assert(pt.toValue.binaryValueAs!Point == pt);

        auto ln = Line(1,2,3);
        assert(ln.toValue.binaryValueAs!Line == ln);

        auto lseg = LineSegment(Point(1,2),Point(3,4));
        assert(lseg.toValue.binaryValueAs!LineSegment == lseg);

        auto b = Box(Point(2,2), Point(1,1));
        assert(b.toValue.binaryValueAs!Box == b);

        auto p = TestPath(false, [Point(1,1), Point(2,2)]);
        assert(p.toValue.binaryValueAs!TestPath == p);

        p = TestPath(true, [Point(1,1), Point(2,2)]);
        assert(p.toValue.binaryValueAs!TestPath == p);

        Polygon poly = [Point(1,1), Point(2,2), Point(3,3)];
        assert(poly.toValue.binaryValueAs!Polygon == poly);

        auto c = TestCircle(Point(1,2), 3);
        assert(c.toValue.binaryValueAs!TestCircle == c);
    }

    // Invalid OID tests
    {
        import std.exception : assertThrown;

        auto v = Point(1,1).toValue;
        v.oidType = OidType.Text;
        assertThrown!ValueConvException(v.binaryValueAs!Point);

        v = Line(1,2,3).toValue;
        v.oidType = OidType.Text;
        assertThrown!ValueConvException(v.binaryValueAs!Line);

        v = LineSegment(Point(1,1), Point(2,2)).toValue;
        v.oidType = OidType.Text;
        assertThrown!ValueConvException(v.binaryValueAs!LineSegment);

        v = Box(Point(1,1), Point(2,2)).toValue;
        v.oidType = OidType.Text;
        assertThrown!ValueConvException(v.binaryValueAs!Box);

        v = TestPath(true, [Point(1,1), Point(2,2)]).toValue;
        v.oidType = OidType.Text;
        assertThrown!ValueConvException(v.binaryValueAs!TestPath);

        v = [Point(1,1), Point(2,2)].toValue;
        v.oidType = OidType.Text;
        assertThrown!ValueConvException(v.binaryValueAs!Polygon);

        v = TestCircle(Point(1,1), 3).toValue;
        v.oidType = OidType.Text;
        assertThrown!ValueConvException(v.binaryValueAs!TestCircle);
    }

    // Invalid data size
    {
        import std.exception : assertThrown;

        auto v = Point(1,1).toValue;
        v._data = new ubyte[1];
        assertThrown!ValueConvException(v.binaryValueAs!Point);

        v = Line(1,2,3).toValue;
        v._data.length = 1;
        assertThrown!ValueConvException(v.binaryValueAs!Line);

        v = LineSegment(Point(1,1), Point(2,2)).toValue;
        v._data.length = 1;
        assertThrown!ValueConvException(v.binaryValueAs!LineSegment);

        v = Box(Point(1,1), Point(2,2)).toValue;
        v._data.length = 1;
        assertThrown!ValueConvException(v.binaryValueAs!Box);

        v = TestPath(true, [Point(1,1), Point(2,2)]).toValue;
        v._data.length -= 16;
        assertThrown!ValueConvException(v.binaryValueAs!TestPath);
        v._data.length = 1;
        assertThrown!ValueConvException(v.binaryValueAs!TestPath);

        v = [Point(1,1), Point(2,2)].toValue;
        v._data.length -= 16;
        assertThrown!ValueConvException(v.binaryValueAs!Polygon);
        v._data.length = 1;
        assertThrown!ValueConvException(v.binaryValueAs!Polygon);

        v = TestCircle(Point(1,1), 3).toValue;
        v._data.length = 1;
        assertThrown!ValueConvException(v.binaryValueAs!TestCircle);
    }
}

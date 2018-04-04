/++
    Module to handle PostgreSQL array types
+/
module dpq2.conv.arrays;

import dpq2.oids : OidType;
import dpq2.value;

import std.traits : isArray;
import std.typecons : Nullable;

@safe:

template isArrayType(T)
{
    import dpq2.conv.geometric : isValidPolygon;
    import std.range : ElementType;
    import std.traits : Unqual;

    enum isArrayType = isArray!T && !isValidPolygon!T && !is(Unqual!(ElementType!T) == ubyte) && !is(T : string);
}

static assert(isArrayType!(int[]));
static assert(!isArrayType!(ubyte[]));
static assert(!isArrayType!(string));

/// Converts dynamic or static array of supported types to the coresponding PG array type value
Value toValue(T)(auto ref T v)
if (isArrayType!T)
{
    import dpq2.oids : detectOidTypeFromNative, oidConvTo;
    import std.array : Appender;
    import std.bitmanip : nativeToBigEndian;
    import std.exception : enforce;
    import std.format : format;
    import std.traits : isStaticArray;

    static void writeItem(R, T)(ref R output, T item)
    {
        static if (is(T == ArrayElementType!T))
        {
            import dpq2.conv.from_d_types : toValue;

            static immutable ubyte[] nullVal = [255,255,255,255]; //special length value to indicate null value in array
            auto v = item.toValue; // TODO: Direct serialization to buffer would be more effective
            if (v.isNull) output ~= nullVal;
            else
            {
                auto l = v._data.length;
                enforce(l < uint.max, format!"Array item can't be larger than %s"(uint.max-1)); // -1 because uint.max is a null special value
                output ~= (cast(uint)l).nativeToBigEndian[]; // write item length
                output ~= v._data;
            }
        }
        else
        {
            foreach (i; item)
                writeItem(output, i);
        }
    }

    alias ET = ArrayElementType!T;
    enum dimensions = arrayDimensions!T;
    enum elemOid = detectOidTypeFromNative!ET;
    auto arrOid = oidConvTo!("array")(elemOid); //TODO: check in CT for supported array types

    // check for null value
    static if (!isStaticArray!T)
    {
        if (v is null) return Value(ValueFormat.BINARY, arrOid);
    }

    // check for null element
    static if (__traits(compiles, v[0] is null) || is(ET == Nullable!R,R))
    {
        bool hasNull = false;
        foreach (vv; v)
        {
            static if (is(ET == Nullable!R,R)) hasNull = vv.isNull;
            else hasNull = vv is null;

            if (hasNull) break;
        }
    }
    else bool hasNull = false;

    auto buffer = Appender!(immutable(ubyte)[])();

    // write header
    buffer ~= dimensions.nativeToBigEndian[]; // write number of dimensions
    buffer ~= (hasNull ? 1 : 0).nativeToBigEndian[]; // write null element flag
    buffer ~= (cast(int)elemOid).nativeToBigEndian[]; // write elements Oid
    size_t[dimensions] dlen;
    static foreach (d; 0..dimensions)
    {
        dlen[d] = getDimensionLength!d(v);
        enforce(dlen[d] < uint.max, format!"Array length can't be larger than %s"(uint.max));
        buffer ~= (cast(uint)dlen[d]).nativeToBigEndian[]; // write number of dimensions
        buffer ~= 1.nativeToBigEndian[]; // write left bound index (PG indexes from 1 implicitly)
    }

    //write data
    foreach (i; v) writeItem(buffer, i);

    return Value(buffer.data, arrOid);
}

@system unittest
{
    import dpq2.conv.to_d_types : as;
    import dpq2.result : asArray;

    {
        int[3][2][1] arr = [[[1,2,3], [4,5,6]]];

        assert(arr[0][0][2] == 3);
        assert(arr[0][1][2] == 6);

        auto v = arr.toValue();
        assert(v.oidType == OidType.Int4Array);

        auto varr = v.asArray;
        assert(varr.length == 6);
        assert(varr.getValue(0,0,2).as!int == 3);
        assert(varr.getValue(0,1,2).as!int == 6);
    }

    {
        int[][][] arr = [[[1,2,3], [4,5,6]]];

        assert(arr[0][0][2] == 3);
        assert(arr[0][1][2] == 6);

        auto v = arr.toValue();
        assert(v.oidType == OidType.Int4Array);

        auto varr = v.asArray;
        assert(varr.length == 6);
        assert(varr.getValue(0,0,2).as!int == 3);
        assert(varr.getValue(0,1,2).as!int == 6);
    }

    {
        string[] arr = ["foo", "bar", "baz"];

        auto v = arr.toValue();
        assert(v.oidType == OidType.TextArray);

        auto varr = v.asArray;
        assert(varr.length == 3);
        assert(varr[0].as!string == "foo");
        assert(varr[1].as!string == "bar");
        assert(varr[2].as!string == "baz");
    }

    {
        string[] arr = ["foo", null, "baz"];

        auto v = arr.toValue();
        assert(v.oidType == OidType.TextArray);

        auto varr = v.asArray;
        assert(varr.length == 3);
        assert(varr[0].as!string == "foo");
        assert(varr[1].as!string == "");
        assert(varr[2].as!string == "baz");
    }

    {
        Nullable!string[] arr = [Nullable!string("foo"), Nullable!string.init, Nullable!string("baz")];

        auto v = arr.toValue();
        assert(v.oidType == OidType.TextArray);

        auto varr = v.asArray;
        assert(varr.length == 3);
        assert(varr[0].as!string == "foo");
        assert(varr[1].isNull);
        assert(varr[2].as!string == "baz");
    }
}

package:

template ArrayElementType(T)
{
    import std.range : ElementType;
    import std.traits : isArray, isSomeString;

    static if (!isArrayType!T) alias ArrayElementType = T;
    else alias ArrayElementType = ArrayElementType!(ElementType!T);
}

unittest
{
    static assert(is(ArrayElementType!(int[][][]) == int));
    static assert(is(ArrayElementType!(int[]) == int));
    static assert(is(ArrayElementType!(int) == int));
    static assert(is(ArrayElementType!(string[][][]) == string));
    static assert(is(ArrayElementType!(bool[]) == bool));
}

template arrayDimensions(T)
if (isArray!T)
{
    import std.range : ElementType;

    static if (is(ElementType!T == ArrayElementType!T)) enum int arrayDimensions = 1;
    else enum int arrayDimensions = 1 + arrayDimensions!(ElementType!T);
}

unittest
{
    static assert(arrayDimensions!(bool[]) == 1);
    static assert(arrayDimensions!(int[][]) == 2);
    static assert(arrayDimensions!(int[][][]) == 3);
    static assert(arrayDimensions!(int[][][][]) == 4);
}

auto getDimensionLength(int idx, T)(T v)
{
    import std.range : ElementType;
    import std.traits : isStaticArray;

    static assert(idx >= 0 || !is(T == ArrayElementType!T), "Dimension index out of bounds");

    static if (idx == 0) return v.length;
    else
    {
        // check same lengths on next dimension
        static if (!isStaticArray!(ElementType!T))
        {
            import std.algorithm : map, max, min, reduce;
            import std.exception : enforce;

            auto lengths = v.map!(a => a.length).reduce!(min, max);
            enforce(lengths[0] == lengths[1], "Different lengths of sub arrays");
        }

        return getDimensionLength!(idx-1)(v[0]);
    }
}

unittest
{
    {
        int[3][2][1] arr = [[[1,2,3], [4,5,6]]];
        assert(getDimensionLength!0(arr) == 1);
        assert(getDimensionLength!1(arr) == 2);
        assert(getDimensionLength!2(arr) == 3);
    }

    {
        int[][][] arr = [[[1,2,3], [4,5,6]]];
        assert(getDimensionLength!0(arr) == 1);
        assert(getDimensionLength!1(arr) == 2);
        assert(getDimensionLength!2(arr) == 3);
    }

    {
        import std.exception : assertThrown;
        int[][] arr = [[1,2,3], [4,5]];
        assert(getDimensionLength!0(arr) == 2);
        assertThrown(getDimensionLength!1(arr) == 3);
    }
}

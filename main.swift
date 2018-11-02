import Foundation
import CoreGraphics

struct Extents {
    let minX: Double
    let minY: Double
    let maxX: Double
    let maxY: Double
}

// Utility function to print progress
var lastPercent: Int = -1
func progress(_ current: Int, _ total: Int) {

    var percent = Int(10 * round((Double(current) / Double(total)) * 10))
    percent = percent >= 100 ? 100 : percent
    if percent > lastPercent {
        lastPercent = percent
        print("\(percent)%")
    }
}

// Utility function to run an SQL command that expects no returned values
func execSql(_ conn: OpaquePointer, _ sql: String) {
    let res = PQexec(conn, sql)
    if (PQresultStatus(res) != PGRES_COMMAND_OK) {
        print("PQexec failed starting transaction: \(String(cString: PQerrorMessage(conn)))")
        PQclear(res)
        exit(0)
    }
    PQclear(res)
}

func getExtents(_ wkt: String) -> Extents {

    let GEOS_HANDLE = GEOS_init_r()
    let WKTReader = GEOSWKTReader_create_r(GEOS_HANDLE)

    let GEOSGeom = GEOSWKTReader_read_r(GEOS_HANDLE, WKTReader, wkt)

    var minX: Double = 0.0
    var minY: Double = 0.0
    var maxX: Double = 0.0
    var maxY: Double = 0.0

    GEOSGeom_getXMin_r(GEOS_HANDLE, GEOSGeom, &minX)
    GEOSGeom_getYMin_r(GEOS_HANDLE, GEOSGeom, &minY)
    GEOSGeom_getXMax_r(GEOS_HANDLE, GEOSGeom, &maxX)
    GEOSGeom_getYMax_r(GEOS_HANDLE, GEOSGeom, &maxY)

    GEOSWKTReader_destroy_r(GEOS_HANDLE, WKTReader)
    GEOSGeom_destroy_r(GEOS_HANDLE, GEOSGeom)

    return Extents(minX: minX, minY: minY, maxX: maxX, maxY: maxY)

}

func getExtents(_ conn: OpaquePointer, _ query: String) -> Extents {

    print("Generating the extents")
    
    let res = PQexec(conn, "with foo(geom) as ( \(query) ) select st_astext(st_extent(geom)) from foo")

    if PQresultStatus(res) != PGRES_TUPLES_OK {
        print("PQexec failed while getting extents: \(String(cString: PQerrorMessage(conn)))")
        PQclear(res)
        exit(0)
    }
    let data = String.init(cString: PQgetvalue(res, 0, 0))

    PQclear(res)

    return getExtents(data)

}

// Process commandline arguments

if CommandLine.argc <= 1 || CommandLine.arguments.index(of: "-help") != nil || CommandLine.arguments.index(of: "-h") != nil {
    print("-f:\t\t specify the filename to save the image")
    print("-pg:\t\t set the database connection information in the format \"host=hostname.rds.amazonaws.com user=troutspotting dbname=xxx password=yyyy\"")
    print("-query:\t\t an SQL querty that returns the geometry in WKT format along with a numerical value representing the line width")
    print("-extents:\t optionally specify the extents, otherwise this is dynamically calculated")
    print("-imageWidth:\t defaults to 5000; height is auto-calculated to maintain the aspect ratio of the image")
    print("-format:\t defaulted to \"png\". Can be set to \"pdf\" but may not be well suited for large datasets")
    print("-totalrows:\t If the -progress option is set, this parameter sets the total number of anticipated geometrue to be rendered. If not specified, the count is dynamically generated")
    print("Example:")
    print("./gen_image -pg \"host=hostname.rds.amazonaws.com user=username dbname=xxx password=yyyy\" -query \"with extents(geom) as (select st_geomfromtext('POLYGON((-129 23,-129 51,-62 51,-62 23,-129 23))')) select st_astext(shape) from streams join extents on shape && geom\" -extents \"POLYGON((-129 23,-129 51,-62 51,-62 23,-129 23))\" -f output.png")
}

guard let pgIndex = CommandLine.arguments.index(of: "-pg"), CommandLine.arguments.indices.contains(pgIndex+1) else {
    print("Need to provide pg parameter")
    print("Example: -pg host=XXXXX-east-1.rds.amazonaws.com user=XXX dbname=XXX password=XXX")
    exit(0)
}

let pq = CommandLine.arguments[pgIndex+1]

guard let queryIndex = CommandLine.arguments.index(of: "-query"), CommandLine.arguments.indices.contains(queryIndex+1) else {
    print("Need to provide query, such as:")
    print("select st_astext(shape) from streams s join tl_2018_us_state us on s.shape && us.wkb_geometry where us.stusps = 'NY'")
    exit(0)
}

let query = CommandLine.arguments[queryIndex+1]

guard let filePathIndex = CommandLine.arguments.index(of: "-f"), CommandLine.arguments.indices.contains(filePathIndex+1) else {
    print("Need to set a file path for output using -f [PATH]")
    exit(0)
}

let filePath = CommandLine.arguments[filePathIndex+1]

var format = "unknown"
if filePath.hasSuffix("png") {
    format = "png"
} else if filePath.hasSuffix("pdf") {
    format = "pdf"
} else {
    print("Unknown file format \(filePath) - file should be png or pdf")
}

var imageWidth = 5000
if let widthIndex = CommandLine.arguments.index(of: "-width"), CommandLine.arguments.indices.contains(widthIndex+1),
    Int(CommandLine.arguments[widthIndex+1]) != nil {
    imageWidth = Int(CommandLine.arguments[widthIndex+1])!
}

var extentsProvided: String?
if let extentsIndex = CommandLine.arguments.index(of: "-extents"), CommandLine.arguments.indices.contains(extentsIndex+1) {
    extentsProvided = CommandLine.arguments[extentsIndex+1]
}

var printProgress = CommandLine.arguments.contains("-progress")

var totalRows = 0
if let totalRowsIndex = CommandLine.arguments.index(of: "-totalrows"), CommandLine.arguments.indices.contains(totalRowsIndex+1),
    Int(CommandLine.arguments[totalRowsIndex+1]) != nil {
    totalRows = Int(CommandLine.arguments[totalRowsIndex+1])!
    printProgress = true
}

let increment = 1000 // the batch size of results fetched via a cursor

print("Connecting to database using: \"\(pq)\"")
print("Output format: \(format)")
print("Query: \"\(query)\"")
print("Image Width: \(imageWidth)")
print("File path: \(filePath)")

guard let conn = PQconnectdb(pq), PQstatus(conn) == CONNECTION_OK else {
    print("Unable to connect to the database using \(pq)")
    exit(0)
}

// Get the extents
let extents = extentsProvided == nil ? getExtents(conn, query) : getExtents(extentsProvided!)
let lineWidth = extents.maxX - extents.minX
let lineHeight = extents.maxY - extents.minY
let aspectRatio = lineWidth / lineHeight
let imageHeight = Int(Double(imageWidth) / aspectRatio)

print("Extents: \(extents)")
print("lineWidth: \(lineWidth) lineHeight: \(lineHeight) aspectRatio: \(aspectRatio) imageWidth: \(imageWidth) imageHeight: \(imageHeight)")

execSql(conn, "BEGIN")
execSql(conn, "DECLARE mycursor CURSOR FOR \(query)")

var GEOS_HANDLE = GEOS_init_r()
let WKTReader = GEOSWKTReader_create_r(GEOS_HANDLE)
let scale = 1.0
let imageToLineWidthRatio = Double(imageWidth) / lineWidth
let imageToLineHeightRatio = Double(imageHeight) / lineHeight

print("Scale: \(scale) imageToLineWidthRatio: \(imageToLineWidthRatio) imageToLineHeightRatio: \(imageToLineHeightRatio) ")

// Init CoreGraphics

let colorSpace = CGColorSpaceCreateDeviceRGB()
let size = CGSize(width: imageWidth, height: imageHeight)

let url = NSURL(fileURLWithPath: filePath)

var context: CGContext?

if format == "png" {
    let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
    context = CGContext.init(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace, bitmapInfo: bitmapInfo.rawValue)
} else {
    var mediaBox: CGRect = CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight)
    context = CGContext(url, mediaBox: &mediaBox, nil)
    let boxData = NSData(bytes: &mediaBox, length: MemoryLayout.size(ofValue: mediaBox))
    let pageInfo = [ kCGPDFContextMediaBox as String: boxData ]
    context?.beginPDFPage(pageInfo as NSDictionary)
}

context?.setShouldAntialias(true)
context?.setStrokeColor(CGColor.white)
context?.setFillColor(CGColor.black)
context?.fill(CGRect(origin: CGPoint(x: 0, y: 0), size: size))
context?.setLineCap(.round)
context?.setLineJoin(.round)

// Progress meter
if printProgress && totalRows == 0 {
    let res = PQexec(conn, "with data as (\(query)) select count(*) from data")
    if PQresultStatus(res) != PGRES_TUPLES_OK {
        print("PQexec failed declaring cursor: \(String(cString: PQerrorMessage(conn)))")
        PQclear(res)
        exit(0)
    }
    totalRows = Int(String(cString: PQgetvalue(res, 0, 0)))!
    print("Total rows calculated as \(totalRows)")
    PQclear(res)
}

var hasData = true
var count = 0

print("Start rendering...")


while hasData {

    let res = PQexec(conn, "fetch forward \(increment) from mycursor")
    if PQresultStatus(res) != PGRES_TUPLES_OK {
        print("PQexec failed declaring cursor: \(String(cString: PQerrorMessage(conn)))")
        PQclear(res)
        exit(0)
    }
    
    let numRows = PQntuples(res)

    hasData = numRows > 0

    if !hasData {
        print("Finished retrieving data")
    }

    count += increment
    if printProgress {
        progress(count, totalRows)
    }
    
    for row in 0..<numRows {
 
        let data = String(cString: PQgetvalue(res, row, 0))
        
        var length:CGFloat = CGFloat(Float(String(cString: PQgetvalue(res, row, 1)))!)
        if length > 10 {
            length = 1.0
        }
        
        let GEOSGeom = GEOSWKTReader_read_r(GEOS_HANDLE, WKTReader, data)

        let geometryTypeId = GEOSGeomTypeId_r(GEOS_HANDLE, GEOSGeom)
        if geometryTypeId != GEOS_LINESTRING.rawValue {
            print("Geometry must be a linestring")
            continue
        }

        let sequence = GEOSGeom_getCoordSeq_r(GEOS_HANDLE, GEOSGeom)
        var numCoordinates: UInt32 = 0
        GEOSCoordSeq_getSize_r(GEOS_HANDLE, sequence, &numCoordinates)
        context?.beginPath()
        
        context?.setLineWidth(length)
        context?.setStrokeColor(.white)
        context?.setShadow(offset: CGSize(width: 0, height: 0), blur: 30, color: .white)
        
        for i in 0 ..< numCoordinates {

            var thisLongitude: Double = 0
            var thisLatitude: Double = 0
            GEOSCoordSeq_getX_r(GEOS_HANDLE, sequence, i, &thisLongitude)
            GEOSCoordSeq_getY_r(GEOS_HANDLE, sequence, i, &thisLatitude)

            let thisX = (extents.minX - thisLongitude) * -1 * imageToLineWidthRatio * scale
            let thisY = (thisLatitude - extents.minY)  * imageToLineHeightRatio * scale

            if (i == 0) {
                context?.move(to: CGPoint(x: thisX, y: thisY))
            } else {
                context?.addLine(to: CGPoint(x: thisX, y: thisY))
            }
        }

        context?.strokePath()
        
        GEOSGeom_destroy_r(GEOS_HANDLE, GEOSGeom)
        
    }
    PQclear(res)
}

print("Generating output to \(filePath)")

if format == "png" {
    let image = context?.makeImage()
    let destination = CGImageDestinationCreateWithURL(url, kUTTypePNG, 1, nil)
    CGImageDestinationAddImage(destination!, image!, nil)
    CGImageDestinationFinalize(destination!)
}

if format == "pdf" {
    context?.endPDFPage()
    context?.closePDF()
}

execSql(conn, "CLOSE mycursor")
execSql(conn, "END")
PQfinish(conn)
GEOSWKTReader_destroy_r(GEOS_HANDLE, WKTReader)

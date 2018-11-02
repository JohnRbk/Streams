import Foundation
import CoreGraphics

struct Extents {
    let minX: Double
    let minY: Double
    let maxX: Double
    let maxY: Double
}

enum FileFormat:String {
    case png
    case pdf
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
        exit(1)
    }
    PQclear(res)
}

// Utility to generate extents from a WTK string
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

// Utility to generate extents from an SQL query
func getExtents(_ conn: OpaquePointer, _ query: String) -> Extents {

    print("Generating the extents")
    
    let res = PQexec(conn, "with foo(geom) as ( \(query) ) select st_astext(st_extent(geom)) from foo")

    if PQresultStatus(res) != PGRES_TUPLES_OK {
        print("PQexec failed while getting extents: \(String(cString: PQerrorMessage(conn)))")
        PQclear(res)
        exit(1)
    }
    let data = String.init(cString: PQgetvalue(res, 0, 0))

    PQclear(res)

    return getExtents(data)

}

// Commandline argument utility
func getRequiredOpt(option: String, errorMessage: String) -> String {
    guard let index = CommandLine.arguments.index(of: option), CommandLine.arguments.indices.contains(index + 1) else {
        print(errorMessage)
        exit(1)
    }
    return CommandLine.arguments[index+1]
}

// Commandline argument utility
func getOpt(option: String) -> String? {
    guard let index = CommandLine.arguments.index(of: option), CommandLine.arguments.indices.contains(index + 1) else {
        return nil
    }
    return CommandLine.arguments[index+1]
}

// Process commandline arguments

if CommandLine.argc <= 1 || CommandLine.arguments.index(of: "-help") != nil || CommandLine.arguments.index(of: "-h") != nil {
    print("""
        -f:             Specify the filename to save the image
        -pg:            Set the database connection information in the format \"host=hostname.rds.amazonaws.com user=troutspotting dbname=xxx password=yyyy\"
        -query:         An SQL querty that returns the geometry in WKT format along with a numerical value representing the line width
        -extents:       Optional. Specify the extents in WKT format, otherwise this is dynamically calculated
        -imageWidth:    Defaults to 5000; height is auto-calculated to maintain the aspect ratio of the image
        -scale:         Defaults to 1.0
        -totalrows:     Optional, ignored if progress is not enabled. When set, it prevents a dynamic calculation of total rows of data to render, improving performance when the total row count calculation is time consuming.
        Example:
        ./gen_image -pg \"host=hostname.rds.amazonaws.com user=username dbname=xxx password=yyyy\" -query \"with extents(geom) as (select st_geomfromtext('POLYGON((-129 23,-129 51,-62 51,-62 23,-129 23))')) select st_astext(shape) from streams join extents on shape && geom\" -extents \"POLYGON((-129 23,-129 51,-62 51,-62 23,-129 23))\" -f output.png
    """)
    exit(1)
}

// Get commandline arguments
let pq = getRequiredOpt(option: "-pg", errorMessage: "Need to provide -pg parameter")
let query = getRequiredOpt(option: "-query", errorMessage: "Need to provide a query param using -query")
let filePath = getRequiredOpt(option: "-f", errorMessage: "Need to specify an output file path using -f")
let url = NSURL(fileURLWithPath: filePath)
guard let fileSuffix = url.pathExtension, let format = FileFormat(rawValue: fileSuffix) else {
    print("Invalid file format: \(filePath)")
    exit(1)
}

let imageWidth = getOpt(option: "-width") == nil ? 5000 : Int(getOpt(option: "-width")!)!
let extentsProvided = getOpt(option: "-extents")
let printProgress = CommandLine.arguments.contains("-progress")
var totalRows = getOpt(option: "-totalrows") == nil ? 0 : Int(getOpt(option: "-totalrows")!)!
var scale = getOpt(option: "-scale") == nil ? 1.0 : Double(getOpt(option: "-scale")!)!
let increment = 1000 // the batch size of results fetched via a cursor

print("Connecting to database using: \"\(pq)\"")
print("Output format: \(format)")
print("Query: \"\(query)\"")
print("Image Width: \(imageWidth)")
print("File path: \(filePath)")
print("Image scale: \(scale)")

// Connect to the database
guard let conn = PQconnectdb(pq), PQstatus(conn) == CONNECTION_OK else {
    print("Unable to connect to the database using \(pq)")
    exit(1)
}

// If no estimate row count was provided using -totalrows, dynamically calculate it
// This may be a slow query, so its generally best to estimate the total rows
// for large data sets
if printProgress && totalRows == 0 {
    let res = PQexec(conn, "with data as (\(query)) select count(*) from data")
    if PQresultStatus(res) != PGRES_TUPLES_OK {
        print("PQexec failed declaring cursor: \(String(cString: PQerrorMessage(conn)))")
        PQclear(res)
        exit(1)
    }
    totalRows = Int(String(cString: PQgetvalue(res, 0, 0)))!
    print("Total rows calculated as \(totalRows)")
    PQclear(res)
}

// Get the extents
let extents = extentsProvided == nil ? getExtents(conn, query) : getExtents(extentsProvided!)
let lineWidth = extents.maxX - extents.minX
let lineHeight = extents.maxY - extents.minY
let aspectRatio = lineWidth / lineHeight
let imageHeight = Int(Double(imageWidth) / aspectRatio)

print("Extents: \(extents)")
print("lineWidth: \(lineWidth) lineHeight: \(lineHeight) aspectRatio: \(aspectRatio) imageWidth: \(imageWidth) imageHeight: \(imageHeight)")

// Begin a transaction; this is required for a cursor
execSql(conn, "BEGIN")

// Using a cursor keeps memory usage to a minimim
execSql(conn, "DECLARE mycursor CURSOR FOR \(query)")

// Initialize the GEOS library. This is used to convert the PostGIS geometry into something
// that can be used in code
var GEOS_HANDLE = GEOS_init_r()
let WKTReader = GEOSWKTReader_create_r(GEOS_HANDLE)

// These ratios are used during the conversion of lat/lon to x/y screen coordinates
let imageToLineWidthRatio = Double(imageWidth) / lineWidth
let imageToLineHeightRatio = Double(imageHeight) / lineHeight

// Init CoreGraphics
let colorSpace = CGColorSpaceCreateDeviceRGB()
let size = CGSize(width: imageWidth, height: imageHeight)
var context: CGContext?

if format == .png {
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
//context?.setFillColor(.black)
//context?.setStrokeColor(.white)
context?.setFillColor(.white)
let darkBlue = CGColor(red: 0.495, green: 0.615, blue: 0.905, alpha: 1.0)
let lightBlue = CGColor(red: 0.125, green: 0.278, blue: 0.615, alpha: 1.0)
context?.setStrokeColor(lightBlue)

context?.fill(CGRect(origin: CGPoint(x: 0, y: 0), size: size))
context?.setLineCap(.round)
context?.setLineJoin(.round)

var hasData = true
var count = 0

print("Start rendering...")

while hasData {

    let res = PQexec(conn, "fetch forward \(increment) from mycursor")
    if PQresultStatus(res) != PGRES_TUPLES_OK {
        print("PQexec failed declaring cursor: \(String(cString: PQerrorMessage(conn)))")
        PQclear(res)
        exit(1)
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
        
        let length:CGFloat = CGFloat(Float(String(cString: PQgetvalue(res, row, 1)))!)
        
        let GEOSGeom = GEOSWKTReader_read_r(GEOS_HANDLE, WKTReader, data)

        let geometryTypeId = GEOSGeomTypeId_r(GEOS_HANDLE, GEOSGeom)
        if geometryTypeId != GEOS_LINESTRING.rawValue {
            print("Geometry must be a linestring, skipping")
            continue
        }

        let sequence = GEOSGeom_getCoordSeq_r(GEOS_HANDLE, GEOSGeom)
        var tmpNumCoordinates: UInt32 = 0
        GEOSCoordSeq_getSize_r(GEOS_HANDLE, sequence, &tmpNumCoordinates)
        let numCoordinates = Int(tmpNumCoordinates)

        var xy = Array(repeating: Array(repeating: Double(0.0), count: 2), count: numCoordinates)
        
        for i in 0 ..< numCoordinates {

            var longitude: Double = 0
            var latitude: Double = 0
            
            GEOSCoordSeq_getX_r(GEOS_HANDLE, sequence, UInt32(i), &longitude)
            GEOSCoordSeq_getY_r(GEOS_HANDLE, sequence, UInt32(i), &latitude)

            xy[i][0] = (extents.minX - longitude) * -1 * imageToLineWidthRatio * scale
            xy[i][1] = (latitude - extents.minY)  * imageToLineHeightRatio * scale

        }
        
        // Drawing sequence
        context?.beginPath()
        context?.setLineWidth(length)
        context?.setShadow(offset: CGSize(width: 0, height: 0), blur: length*3, color: darkBlue)
        
        for i in 0 ..< numCoordinates {
            let p = CGPoint(x: xy[i][0], y: xy[i][1])
            i == 0 ? context?.move(to: p) : context?.addLine(to: p)
        }
        context?.strokePath()
        
        GEOSGeom_destroy_r(GEOS_HANDLE, GEOSGeom)
        
    }
    PQclear(res)
}

print("Generating output to \(filePath)")

switch format {
case .png:
    let image = context?.makeImage()
    let destination = CGImageDestinationCreateWithURL(url, kUTTypePNG, 1, nil)
    CGImageDestinationAddImage(destination!, image!, nil)
    CGImageDestinationFinalize(destination!)
case .pdf:
    context?.endPDFPage()
    context?.closePDF()
}

execSql(conn, "CLOSE mycursor")
execSql(conn, "END")
PQfinish(conn)
GEOSWKTReader_destroy_r(GEOS_HANDLE, WKTReader)

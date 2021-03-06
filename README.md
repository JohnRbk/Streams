# Streams

Generate beautiful images as PNG or vector PDF files from PostGIS, ideally suited for rendering rivers and streams such as the [National Hydrography Dataset](https://www.usgs.gov/core-science-systems/ngp/national-hydrography).

![US Rivers](Images/us-rivers.png)

[Link to high-res image](Images/us-rivers-high-res.png)

![US Rivers](Images/northeast.png)

[Link to high-res image](Images/northeast-high-res.png)

## Motivation

QGIS and Mapbox are great tools for styling map data. For quick visualizations, however, they may be too complicated. [GDAL rasterize](https://www.gdal.org/gdal_rasterize.html) and built-in PostGIS functions such as [ST_AsPNG](https://postgis.net/docs/RT_ST_AsPNG.html) provide good capabilities to render images from a database, but lack some of the styling options provided by Apple's CoreGraphics. 

The `gen_image` tool was purpose-built to run efficiently and generate large images with little effort.

Note: The current version of `gen_image` only supports geometries of type LINESTRING.

## Prerequisites

[Libgeos](https://trac.osgeo.org/geos/) is required. Download the latest version, build it and install it using the default settings. The Makefile looks for the library in /usr/local/lib.

The commandline tool  `gen_image` requires a connection to a PostgreSQL database. 

Generate an image from a table `nhdflowline` with a 1-pixel width:

```bash
./gen_image -pg "host=localhost user=admin dbname=mydb password=XXX" -query "select st_astext(shape), 1 from nhdflowline where id = 2" -f output.png 
```

The query must contain two columns: the first must be a geography in WKT format (the st_astext function converts it to a WKT format). The second column must be a number corresponding to the width of the line that will be rendered.

The following example show how to generate an image from a table centered around New York with a width calculated using the length. The `ST_Simplify` function improves rendering performance for large geometries.

```bash
./gen_image -pg "host=localhost user=admin dbname=mydb password=XXX" -query \
"select st_astext(st_simplify(shape,0.005)), \
case \
when stream_length < 10000 then 0.5 \
when stream_length < 100000 then 2 \
else 3 \
end as length \
from nhdflowline s join tl_2018_us_state us on s.shape && us.wkb_geometry \
where us.stusps = 'NY'" \
-progress -f foo.png
```

## Installing

Build `gen_image` using XCode or the included Makefile

## Built With

* [GEOS](https://trac.osgeo.org/geos//)
* [PostGIS](https://maven.apache.org/)

## Authors

John Robokos

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details

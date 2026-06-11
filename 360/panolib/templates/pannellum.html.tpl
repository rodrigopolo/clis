<!DOCTYPE html>
<html>
<head>
	<meta charset="utf-8">
	<title>${TITLE}</title>
	<meta name="description" content="${DESCRIPTION}">

	<!-- Open Graph -->
	<meta property="og:title" content="${TITLE}" />
	<meta property="og:description" content="${DESCRIPTION}" />
	<meta property="og:image" content="og_image.jpg" />
	<meta property="og:url" content="${OG_URL}" />
	<meta property="og:type" content="website" />

	<!-- Twitter -->
	<meta name="twitter:card" content="summary_large_image" />
	<meta name="twitter:title" content="${TITLE}" />
	<meta name="twitter:description" content="${DESCRIPTION}" />
	<meta name="twitter:image" content="og_image.jpg" />

	<meta name="viewport" content="target-densitydpi=device-dpi, width=device-width, initial-scale=1.0, maximum-scale=1.0, minimum-scale=1.0, user-scalable=no, minimal-ui" />
	<style>@-ms-viewport { width: device-width; }</style>
	<link rel="stylesheet" href="//cdn.jsdelivr.net/npm/pannellum@2.5.7/build/pannellum.min.css">
	<link rel="stylesheet" href="pannellum.2.5.7/style.css"/>
</head>
<body>

	<div id="pano"></div>

	<script src="//cdn.jsdelivr.net/npm/pannellum@2.5.7/build/pannellum.min.js"></script>
	<script>
		var panorama = {
			"autoLoad": true,
			"type": "multires",
			"preview": "tiles/1/f_0_0.jpg",
			"minHfov": 10,
			"maxHfov": 140,
			"hfov": 90,
			"multiResMinHfov": true,
			"multiRes": {
				"basePath": "tiles",
				"path": "/%l/%s_%y_%x",
				"fallbackPath": "/fallback/%s",
				"extension": "jpg",
				"tileResolution": ${TILE_RESOLUTION},
				"maxLevel": ${MAX_LEVEL},
				"cubeResolution": ${CUBE_RESOLUTION}
			},
			domid: "pano"
		}
		pannellum.viewer(panorama.domid, panorama);
	</script>

</body>
</html>

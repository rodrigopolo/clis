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

	<meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, minimum-scale=1.0, user-scalable=no, minimal-ui" />
	<style>@-ms-viewport { width: device-width; }</style>
	<link rel="stylesheet" href="marzipano.0.10.2/style.css">
</head>
<body>

	<div id="pano"></div>

	<script type="text/javascript">
		var panorama = {
			prefix: "tiles",
			domid: "pano",
			tiles: ${PANO_TILES},
		}
	</script>
	<script src="//cdnjs.cloudflare.com/ajax/libs/marzipano/0.10.2/marzipano.min.js" integrity="sha512-yXzJzoGCljUpxjkFmg+6No2leY9Dp0/PpQiVkIQ+uZLAb5xwsTAY2I5l/Wm7rmjDk0nRh3Q2Cr5T5cSh1OHJBw==" crossorigin="anonymous" referrerpolicy="no-referrer"></script>
	<script src="marzipano.0.10.2/main.js"></script>

</body>
</html>

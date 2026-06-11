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
	<link rel="stylesheet" href="avansel.0.0.17/style.css"/>
</head>
<body>

	<div id="pano"></div>

	<script type="text/javascript">
		const panorama = {
			prefix: "tiles",
			domid: "pano",
			tiles: ${PANO_TILES}
		}
	</script>
	<script async src="//unpkg.com/es-module-shims@2.8.1/dist/es-module-shims.js"></script>
	<script type="importmap">{"imports":{"avansel":"https://unpkg.com/avansel@0.0.17/build/avansel.js"}}</script>
	<script type="module" src="avansel.0.0.17/main.js"></script>

</body>
</html>

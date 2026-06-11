<!DOCTYPE html>
<html>
<head>
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

	<meta name="viewport" content="width=device-width, initial-scale=1.0, minimum-scale=1.0, maximum-scale=1.0, viewport-fit=cover" />
	<meta name="apple-mobile-web-app-capable" content="yes" />
	<meta name="apple-mobile-web-app-status-bar-style" content="black" />
	<meta name="mobile-web-app-capable" content="yes" />
	<meta http-equiv="Content-Type" content="text/html;charset=utf-8" />
	<meta http-equiv="x-ua-compatible" content="IE=edge" />
	<link href="${KRPANO_DIR}/style.css" rel="stylesheet">
</head>
<body>
	<script src="${KRPANO_DIR}/tour.js"></script>
	<div id="pano" style="width:100%;height:100%;">
		<noscript>
			<table style="width:100%;height:100%;">
				<tr style="vertical-align:middle;">
					<td>
						<div style="text-align:center;">ERROR:<br/>
							<br/>
							Javascript not activated<br/>
							<br/>
						</div>
					</td>
				</tr>
			</table>
		</noscript>
		<script>
			embedpano({
				xml: "tour.xml",
				basepath: "${KRPANO_DIR}/"
			});
		</script>
	</div>
</body>
</html>

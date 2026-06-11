<krpano version="1.22" title="${TITLE}">

	<include url="%SWFPATH%/skin/vtourskin.xml" />

	<skin_settings
		maps="true"
		maps_type="arcgis_worldmap"
		maps_zoombuttons="false"
		maps_loadonfirstuse="true"
		gyro="true"
		gyro_keeplookingdirection="false"
		webvr="true"
		webvr_keeplookingdirection="true"
		webvr_prev_next_hotspots="true"
		autotour="false"
		littleplanetintro="false"
		followmousecontrol="false"
		title="true"
		thumbs="true"
		thumbs_width="120" thumbs_height="80" thumbs_padding="10" thumbs_crop="0|40|240|160"
		thumbs_opened="false"
		thumbs_text="false"
		thumbs_dragging="true"
		thumbs_onhoverscrolling="false"
		thumbs_scrollbuttons="false"
		thumbs_scrollindicator="false"
		thumbs_loop="false"
		tooltips_buttons="false"
		tooltips_thumbs="true"
		tooltips_hotspots="true"
		tooltips_mapspots="true"
		deeplinking="false"
		loadscene_flags="MERGE"
		loadscene_blend="OPENBLEND(0.5, 0.0, 0.75, 0.05, linear)"
		loadscene_blend_prev="SLIDEBLEND(0.5, 180, 0.75, linear)"
		loadscene_blend_next="SLIDEBLEND(0.5,   0, 0.75, linear)"
		loadingtext=""
		layout_width="100%"
		layout_maxwidth="814"
		controlbar_width="-24"
		controlbar_height="40"
		controlbar_offset="20"
		controlbar_offset_closed="-40"
		controlbar_overlap.no-fractionalscaling="10"
		controlbar_overlap.fractionalscaling="0"
		design_skin_images="vtourskin.png"
		design_bgcolor="0x2D3E50"
		design_bgalpha="0.8"
		design_bgborder="0"
		design_bgroundedge="1"
		design_bgshadow="0 4 10 0x000000 0.3"
		design_thumbborder_bgborder="3 0xFFFFFF 1.0"
		design_thumbborder_padding="2"
		design_thumbborder_bgroundedge="0"
		design_text_css="color:#FFFFFF; font-family:Arial;"
		design_text_shadow="1"
	/>

	<include url="%SWFPATH%/skin/vtourskin_design_ultra_light.xml" />

	<scene name="scene_image" title="image" onstart="" thumburl="tiles/thumb.jpg" lat="${LAT}" lng="${LNG}" alt="" heading="0.0">
		<control bouncinglimits="calc:image.cube ? true : false" />
		<view hlookat="0.0" vlookat="0.0" fovtype="MFOV" fov="120" maxpixelzoom="2.0" fovmin="70" fovmax="140" limitview="auto" />
		<preview url="tiles/preview.jpg" />
		<image>
			<cube url="tiles/%s/l%l/%0v/l%l_%s_%0v_%0h.jpg" multires="${PANO_TILES}" />
		</image>
	</scene>

</krpano>

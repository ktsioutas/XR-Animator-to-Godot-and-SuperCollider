### sc-dance-modifications

##### xr_animator_vmc_music_rokoko.scd  must be evaluated at Ianis Super Collider

##### also the below snippets

`~enableVmcMusicScDance.value;`

`~onVmcMusicBone = { |bone, values|
    if(bone == \Head) {
        values.postln;
    };
};`

`~stopVmcMusicRokoko.value;`

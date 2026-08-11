### Ianis side  sc-dance-modifications and sc-scipts

##### If a SuperCollider user wants to receive data from XR Animator,  xr_animator_vmc_music_rokoko.scd  must be evaluated in SuperCollider

##### also the below snippets must be evaluated

`~enableVmcMusicScDance.value;`

`~onVmcMusicBone = { |bone, values|
    if(bone == \Head) {
        values.postln;
    };
};`

`~stopVmcMusicRokoko.value;`

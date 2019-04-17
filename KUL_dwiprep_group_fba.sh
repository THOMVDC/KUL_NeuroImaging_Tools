cwd=$(pwd)
ncpu=32

mkdir -p dwiprep/group/fba/dwiintensitynorm/dwi_input
mkdir -p dwiprep/group/fba/dwiintensitynorm/mask_input



cd dwiprep/group/fba

# find the preproced mifs
search_sessions=($(find ${cwd}/dwiprep -type f | grep dwi_preproced_reg2T1w.mif))
num_sessions=${#search_sessions[@]}
    
echo "  Fixel based input dwi: $num_sessions"
echo "    notably: ${search_sessions[@]}"

for i in ${search_sessions[@]}
do

    s=$(echo $i | cut -d'/' -f 3)
    cp $i ${cwd}/dwiprep/group/fba/dwiintensitynorm/dwi_input/${s}_dwi_preproced_reg2T1w.mif

done

# find the preproced masks
search_sessions=($(find ${cwd}/dwiprep -type f | grep dwi_preproced_reg2T1w_mask.nii.gz))
num_sessions=${#search_sessions[@]}
    
echo "  Fixel based input mask: $num_sessions"
echo "    notably: ${search_sessions[@]}"

for i in ${search_sessions[@]}
do

    s=$(echo $i | cut -d'/' -f 3)
    mrconvert $i ${cwd}/dwiprep/group/fba/dwiintensitynorm/mask_input/${s}_dwi_preproced_reg2T1w_mask.mif

done


# Intensity Normalisation
dwiintensitynorm dwiintensitynorm/dwi_input/ dwiintensitynorm/mask_input/ dwiintensitynorm/dwi_output/ dwiintensitynorm/fa_template.mif dwiintensitynorm/fa_template_wm_mask.mif -nthreads $ncpu


# Adding a subject
#dwi2tensor new_subject/dwi_denoised_unringed_preproc_unbiased.mif -mask new_subject/dwi_temp_mask.mif - | tensor2metric - -fa - | mrregister -force \
# ../dwiintensitynorm/fa_template.mif - -mask2 new_subject/dwi_temp_mask.mif -nl_scale 0.5,0.75,1.0 -nl_niter 5,5,15 -nl_warp - /tmp/dummy_file.mif | \
# mrtransform ../dwiintensitynorm/fa_template_wm_mask.mif -template new_subject/dwi_denoised_unringed_preproc_unbiased.mif -warp - - | dwinormalise \ 
# new_subject/dwi_denoised_unringed_preproc_unbiased.mif - ../dwiintensitynorm/dwi_output/new_subject.mif


# Computing an (average) white matter response function
mkdir -p ${cwd}/dwiprep/group/fba/response
foreach -${ncpu} ${cwd}/dwiprep/group/fba/dwiintensitynorm/dwi_output/*.mif : dwi2response tournier IN \
${cwd}/dwiprep/group/fba/response/PRE_response.txt

average_response ${cwd}/dwiprep/group/fba/dwiintensitynorm/dwi_output/*response.txt ${cwd}/dwiprep/group/fba/group_average_response.txt

# Compute new brain mask images
mkdir -p ${cwd}/dwiprep/group/fba/mask
foreach -${ncpu} ${cwd}/dwiprep/group/fba/dwiintensitynorm/dwi_output/*.mif : dwi2mask IN \
${cwd}/dwiprep/group/fba/mask/PRE_mask.mif

# Fibre Orientation Distribution estimation (spherical deconvolution)
# see https://mrtrix.readthedocs.io/en/latest/fixel_based_analysis/st_fibre_density_cross-section.html
#  Note that dwi2fod csd can be used, however here we use dwi2fod msmt_csd (even with single shell data) to benefit from the hard non-negativity constraint, 
#  which has been observed to lead to more robust outcomes:
mkdir -p ${cwd}/dwiprep/group/fba/fod
foreach -${ncpu} ${cwd}/dwiprep/group/fba/dwiintensitynorm/dwi_output/*.mif : dwiextract IN - \
\| dwi2fod msmt_csd - ${cwd}/dwiprep/group/fba/group_average_response.txt ${cwd}/dwiprep/group/fba/fod/PRE_wmfod.mif \
-mask ${cwd}/dwiprep/group/fba/mask/PRE_mask.mif

# Generate a study-specific unbiased FOD template
mkdir -p ${cwd}/dwiprep/group/fba/template
population_template ${cwd}/dwiprep/group/fba/fod -mask_dir ${cwd}/dwiprep/group/fba/mask ${cwd}/dwiprep/group/fba/template/wmfod_template.mif \
 -voxel_size 1.3 -nthreads $ncpu


# Register all subject FOD images to the FOD template
#foreach * : mrregister IN/wmfod.mif -mask1 IN/dwi_mask_upsampled.mif ../template/wmfod_template.mif -nl_warp IN/subject2template_warp.mif IN/template2subject_warp.mif
mkdir -p ${cwd}/dwiprep/group/fba/reg2template
foreach ${cwd}/dwiprep/group/fba/fod/*_wmfod.mif : mrregister IN -mask1 ${cwd}/dwiprep/group/fba/mask/PRE_mask.mif \
 ${cwd}/dwiprep/group/fba/template/wmfod_template.mif \
 -nl_warp ${cwd}/dwiprep/group/fba/reg2template/PRE_subject2template_warp.mif {cwd}/dwiprep/group/fba/reg2template/PRE_template2subject_warp.mif

# Compute the template mask (intersection of all subject masks in template space)
#foreach * : mrtransform IN/dwi_mask_upsampled.mif -warp IN/subject2template_warp.mif -interp nearest -datatype bit IN/dwi_mask_in_template_space.mif
foreach ${cwd}/dwiprep/group/fba/mask/*_mask.mif : mrtransform IN -warp ${cwd}/dwiprep/group/fba/reg2template/PRE_subject2template_warp.mif \
 -interp nearest -datatype bit ${cwd}/dwiprep/group/fba/mask/PRE_dwi_mask_in_template_space.mif

# mrmath */dwi_mask_in_template_space.mif min ../template/template_mask.mif -datatype bit
mrmath ${cwd}/dwiprep/group/fba/mask/*_dwi_mask_in_template_space.mif min ${cwd}/dwiprep/group/fba/template/template_mask.mif -datatype bit

# Compute a white matter template analysis fixel mask
fod2fixel -mask ${cwd}/dwiprep/group/fba/template/template_mask.mif -fmls_peak_value 0.10 ${cwd}/dwiprep/group/fba/template/wmfod_template.mif \
${cwd}/dwiprep/group/fba/template/fixel_mask

# Warp FOD images to template space
#foreach * : mrtransform IN/wmfod.mif -warp IN/subject2template_warp.mif -noreorientation IN/fod_in_template_space_NOT_REORIENTED.mif
foreach ${cwd}/dwiprep/group/fba/fod/*_wmfod.mif : mrtransform IN -warp ${cwd}/dwiprep/group/fba/reg2template/PRE_subject2template_warp.mif \
 -noreorientation ${cwd}/dwiprep/group/fba/fod/PRE_fod_in_template_space_NOT_REORIENTED.mif

# Segment FOD images to estimate fixels and their apparent fibre density (FD)
#foreach * : fod2fixel -mask ../template/template_mask.mif IN/fod_in_template_space_NOT_REORIENTED.mif IN/fixel_in_template_space_NOT_REORIENTED -afd fd.mif
foreach ${cwd}/dwiprep/group/fba/fod/*_fod_in_template_space_NOT_REORIENTED.mif : fod2fixel -mask ${cwd}/dwiprep/group/fba/template/template_mask.mif \
 IN ${cwd}/dwiprep/group/fba/fod/PRE_fixel_in_template_space_NOT_REORIENTED -afd ${cwd}/dwiprep/group/fba/fod/PRE_fd.mif

# Reorient fixels
#foreach * : fixelreorient IN/fixel_in_template_space_NOT_REORIENTED IN/subject2template_warp.mif IN/fixel_in_template_space
foreach ${cwd}/dwiprep/group/fba/fod/*_fixel_in_template_space_NOT_REORIENTED : fixelreorient IN \
 ${cwd}/dwiprep/group/fba/reg2template/PRE_subject2template_warp.mif ${cwd}/dwiprep/group/fba/fod/PRE_fixel_in_template_space

# Assign subject fixels to template fixels
#foreach * : fixelcorrespondence IN/fixel_in_template_space/fd.mif ../template/fixel_mask ../template/fd PRE.mif
foreach ${cwd}/dwiprep/group/fba/fod/*_fd.mif : fixelcorrespondence IN ${cwd}/dwiprep/group/fba/template/fixel_mask {cwd}/dwiprep/group/fba/template//fd ${cwd}/dwiprep/group/fba/fod/PRE.mif

# Compute the fibre cross-section (FC) metric
#foreach * : warp2metric IN/subject2template_warp.mif -fc ../template/fixel_mask ../template/fc IN.mif
foreach ${cwd}/dwiprep/group/fba/reg2template/*_subject2template_warp.mif : warp2metric IN -fc ${cwd}/dwiprep/group/fba/template//fixel_mask ${cwd}/dwiprep/group/fba/template/fc ${cwd}/dwiprep/group/fba/reg2template/PRE.mif

mkdir ../template/log_fc
cp ../template/fc/index.mif ../template/fc/directions.mif ../template/log_fc
foreach * : mrcalc ../template/fc/IN.mif -log ../template/log_fc/IN.mif

# Perform whole-brain fibre tractography on the FOD template
cd ../template
tckgen -angle 22.5 -maxlen 250 -minlen 10 -power 1.0 wmfod_template.mif -seed_image template_mask.mif -mask template_mask.mif -select 20000000 -cutoff 0.10 tracks_20_million.tck

#Reduce biases in tractogram densities



#!/usr/bin/env gnuplot

dat_file="data.dat"
set datafile sep '\t'
set output "data.eps"

col_app                          = 1
col_cache_policy                 = 2
col_dataset                      = 3
col_epoch_total                  = 4

set terminal postscript "Helvetica,16" eps enhance color dl 2 background "white"

set pointsize 1
set size 1,0.45

set tics font ",14" scale 0.5

set style data histogram
set style histogram clustered gap 1
set style fill solid border -1
set boxwidth 0.75 relative

format_str="<awk -F'\\t' '{ if(". \
                              "$".col_app."           ~ \"%s\"     && ". \
                              "$".col_cache_policy."  ~ \"%s\"     ". \
                              ") { print }}' %s "
cmd_filter_dat_by_policy(file,app,policy)=sprintf(format_str, app, policy, file)

set rmargin 0 #2
set lmargin 5 #5.5
set tmargin 1.5 #1.5
set bmargin 0 #2.5

set multiplot layout 3,2

## Y-axis
set ytics offset 0.5,0 #format "%.1f" #nomirror
set grid y

fs_pattern_A = 3
fs_pattern_B = 3
fs_pattern_C = 3

handle_multiplot_location(row, col) = sprintf("set size 0.5, 0.3; set origin %d*0.5, 0.1;", col,row)

# set xrange [-1:3]
set xrange [-1:]

set label "{/Helvetica-Italic Server A}" at graph 0.05, graph 0.9 textcolor rgb "#006000"
set border lc rgb "#006000" lw 2
set key outside left Right top enhanced nobox # autotitles columnhead
set key samplen 2 spacing 1 height 3 width 0 font ',16' maxrows 2 center at graph 1, graph 1.2 #maxrows 1 at graph 0.02, graph 0.975  noopaque
unset xtics

# plot nan to display legend
eval(handle_multiplot_location(0,0))
unset yrange; set yrange [0:1]
unset ytics
plot NaN w histogram fs pattern fs_pattern_A lc rgb "#af2318" t "GNNLab", \
     NaN w histogram fs noborder lc rgb "#ffffff" t " ", \
     NaN w histogram fs pattern fs_pattern_A lc rgb "#f19e38" t "WholeGraph", \
     NaN w histogram fs noborder transparent pattern 6 noborder lc rgb "#000000" t "+CPU", \
     NaN w histogram fs pattern fs_pattern_A lc rgb "#0080ff" t "UGache", \
     NaN w histogram fs noborder transparent pattern 7 noborder lc rgb "#000000" t "+Clique"

unset key
unset label

set xtics nomirror offset 0,0.3
set tics textcolor "black"
eval(handle_multiplot_location(0,0))
unset yrange; set yrange [0:] writeback
set ytics 4
plot cmd_filter_dat_by_policy(dat_file, "gcn_sup", "^GNN"    ) using (column(col_epoch_total)):xticlabels(col_dataset) w histogram fs pattern fs_pattern_A lc rgb "#af2318" t "GNNLab", \
     cmd_filter_dat_by_policy(dat_file, "gcn_sup", "^Cliq"   ) using (column(col_epoch_total)):xticlabels(col_dataset) w histogram fs pattern fs_pattern_A lc rgb "#f19e38" t "WholeGraph", \
     cmd_filter_dat_by_policy(dat_file, "gcn_sup", "Coll*"  ) using (column(col_epoch_total)):xticlabels(col_dataset) w histogram fs pattern fs_pattern_A lc rgb "#0080ff" t "UGache"

eval(handle_multiplot_location(0,0))
set arrow from  graph 0.2, graph -0.17 to graph 0.8, graph -0.17 nohead lt 1 lw 2 lc "#000000" front
set xlabel "GNN Sup." offset 0,0.3
unset grid
set yrange restore
set ytics 4
plot cmd_filter_dat_by_policy(dat_file, "gcn_sup", "^GNN"    ) using (column(col_epoch_total)):xticlabels(col_dataset) w histogram fs pattern fs_pattern_A lc rgb "#af2318" t "GNNLab", \
     cmd_filter_dat_by_policy(dat_file, "gcn_sup", "^Cliq"   ) using (column(col_epoch_total)):xticlabels(col_dataset) w histogram fs transparent pattern 6 lc rgb "#000000" t "+CPU", \
     cmd_filter_dat_by_policy(dat_file, "gcn_sup", "Coll*"  ) using (column(col_epoch_total)):xticlabels(col_dataset) w histogram fs pattern fs_pattern_A lc rgb "#0080ff" t "UGache"


eval(handle_multiplot_location(0,1))
unset xlabel
unset arrow
set grid y
unset yrange; set yrange [0:]
set ytics auto
plot cmd_filter_dat_by_policy(dat_file, "gcn_unsup", "^GNN"  ) using (column(col_epoch_total)):xticlabels(col_dataset) w histogram fs pattern fs_pattern_A lc rgb "#af2318" t "", \
     cmd_filter_dat_by_policy(dat_file, "gcn_unsup", "^Cliq" ) using (column(col_epoch_total)):xticlabels(col_dataset) w histogram fs pattern fs_pattern_A lc rgb "#f19e38" t "", \
     cmd_filter_dat_by_policy(dat_file, "gcn_unsup", "Coll*") using (column(col_epoch_total)):xticlabels(col_dataset) w histogram fs pattern fs_pattern_A lc rgb "#0080ff" t ""

eval(handle_multiplot_location(0,1))
set arrow from  graph 0.2, graph -0.17 to graph 0.8, graph -0.17 nohead lt 1 lw 2 lc "#000000" front
set xlabel "GNN Unsup." offset 0,0.3
unset grid
unset yrange; set yrange [0:]
set ytics auto
plot cmd_filter_dat_by_policy(dat_file, "gcn_unsup", "^GNN"  ) using (column(col_epoch_total)):xticlabels(col_dataset) w histogram fs pattern fs_pattern_A lc rgb "#af2318" t "", \
     cmd_filter_dat_by_policy(dat_file, "gcn_unsup", "^Cliq" ) using (column(col_epoch_total)):xticlabels(col_dataset) w histogram fs transparent pattern 6 lc rgb "#000000" t "", \
     cmd_filter_dat_by_policy(dat_file, "gcn_unsup", "Coll*") using (column(col_epoch_total)):xticlabels(col_dataset) w histogram fs pattern fs_pattern_A lc rgb "#0080ff" t ""

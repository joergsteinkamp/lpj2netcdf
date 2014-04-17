#!/usr/bin/env perl

# TODO: Predefine a hash with the PFTs and abbreviations, to save as long_name and name
#       as well an units.

#use warnings; # activate only when something is added or rewritten
#use strict; # incompatible with mslice
use PDL;
use PDL::NetCDF;
use Fcntl;
use Term::ReadKey;
use Getopt::Long qw(:config no_ignore_case);
use File::Basename;
use Time::gmtime;

$PDL::BIGPDL = 1; 
$|=1;

my $pcall = join(" ", $0, @ARGV);

#parameters
my $in;        # input file name
my $out;       # output file name
my $grid;      # spatial extent of input file
my $unit;      # unit for usage in netcdf file
my $year;      # year to start time axis with
#flags
my $month;     # treat column 3-14 as months (counting starts with 0)
my $invertlat; # invert ordering of latitude in the output file (start with northern most row)
my $centered;  # coordinates are centered of lower left corner position of gridcell (default, CRU)
my $overwrite; # don't ask, overwrite if output file exists
my $modify;    # don't ask, modify if output file exists
my $verbose;   # print what is done
my $help;      # print help message

# set global defaults
my $east  = 179.5;
my $west  = -180.0;
my $north = 90.0;
my $south = -90.0;
my $xres  = 0.5;
my $yres  = 0.5;

GetOptions ("in=s"      => \$in,
            "out=s"     => \$out,
            "grid=s"    => \$grid,
            "unit=s"    => \$unit,
            "year=i"    => \$year,
            "month"     => \$month,
            "Invertlat" => \$invertlat,
            "centered"  => \$centered,
            "help"      => \$help,
            "Overwrite" => \$overwrite,
            "Modify"    => \$modify,
            "verbose"   => \$verbose);

if ($help) {
  print "Convert ascii files produced by LPJ to netcdf files.\n\n";
  print "Required options with parameters:\n\n";
  print "--in <filename>\tname of input file to process.\n";
  print "--out <filename>\tname of output (may already exist).\n\n";
  print "--grid [<north>,<west>,<south>,<east>,<xres>,<yres>]\n";
  print "       | [<xres>,<yres>]\n";
  print "       | <res>\n";
  print "       where you can either specify\n";
  print "       1.) the sourrounding longitude, latitude and the resolution.\n";
  print "       2.) different lon/lat resolution (global grid 180E - 180W, 90N - 90S).\n";
  print "       3.) same lon/lat resolution (global grid 180E - 180W, 90N - 90S).\n";
  print "       Note the separation by comma.\n";
  print "Optional options with parameters:\n\n";
  print "--unit <unit>\t units attribute string to save in NetCDF file.\n";
  print "Optional arguments without parameters:\n\n";
  print "--month     treat columns 3-14 as months (not working so far !!!)\n";
  print "--Invertlat start with northern most row (only valid with --grid)\n";
  print "--centered  coorinates are cell celtered instead of lower left corner (default in CRU)\n";
  print "--Overwrite do not ask, overwrite output file if it exists.\n";
  print "--Modify    do not ask, modify output file if it exists\n";
  print "            (Produces an error if axis sizes do not match).\n";
  print "--verbose   print what is done.\n";
  print "--help      print this help.\n";

  exit;
}

die("File \"$in\" does not exist.\n") if (! -e $in);
die("File \"$in\" has zero size.\n") if (! -s $in);
die("File \"$in\" is not readable.\n") if (! -r $in);

if (!$out) {
  $out = $in;
  $out =~ s/\..*//;
  $out .= ".nc";
}

# PDLs to save the dimensions (lon, lat, time).
# They are used in each case, but initialized different:
#   gridded or not
#   monthly or annual
my $time = null();
my $lon  = null();
my $lat  = null();

# days per month; no leap year!
my $dpm = pdl([31,28,31,30,31,30,31,31,30,31,30,31]);

# initilized later, dimensions depend on grid an temporal resolution
#   points and annual: time, lon, lat, N
my $outdata = null();
# number of different fields to save
my $ndata   = 0;
#######################
### set up the grid ###
#######################

if ($grid) {
  my @grid = split(",", $grid);
  my $n = @grid;
  if ($n == 1 && float($grid[0]) != 0) {
    $xres = $yres = float($grid[0]);
  } elsif ($n == 2 && float($grid[0]) != 0 && float($grid[1]) != 0) {
    $xres = float($grid[0]);
    $yres = float($grid[1]);
  } elsif ($n == 6 && float($grid[4]) != 0 && float($grid[5]) != 0) {
    $north = float($grid[0]);
    $west  = float($grid[1]);
    $south = float($grid[2]);
    $east  = float($grid[3]);
    $xres  = float($grid[4]);
    $yres  = float($grid[5]);
  } else {
    die("Grid \"$grid\" not possible to construct.\n");
  }
  $lat = sequence(int(($north-$south+$yres)/$yres))*$yres + $south + $yres/2;
  $lon = sequence(int(($east-$west+$xres)/$xres))*$xres + $west + $xres/2;

  if ($invertlat) {
    my $clat = $lat->copy;
    $lat .= $clat->mslice([$clat->nelem - 1, 0]);
  }

  if ($verbose) {
    print "areal extend (gridcell midpoints):\n";
    if ($invertlat) {
      print "  south - north: ".$lat->at($lat->nelem-1)." to ".$lat->at(0)."\n";
    } else { 
      print "  north - south: ".$lat->at($lat->nelem-1)." to ".$lat->at(0)."\n";
    }
    print "  west  - east:  ".$lon->at(0)." to ".$lon->at($lon->nelem-1)."\n";
  }
} else { # if ($grid)
    die("No grid extent given: '-g <north>,<west>,<south>,<east>,<xres>,<yres>'!\n");
}

##############################################
### open the output file and save the grid ###
##############################################
my $ncf;
if ($overwrite || ($modify && ! -e $out)) {
  $ncf = PDL::NetCDF->new ("$out", {REVERSE_DIMS => 1, MODE=>O_CREAT});
} elsif ($modify) {
  $ncf = PDL::NetCDF->new ("$out", {REVERSE_DIMS => 1, MODE=>O_RDWR});
} elsif (-e $out && -w $out) {
  ReadMode('cbreak');
  print "File \"$out\" exists (o)verwrite, (m)odify or exit? ";
  my $r = ReadKey(0);
  print "\n" if ($verbose);
  ReadMode('normal');    
  if (lc($r) eq "o") {
    $ncf = PDL::NetCDF->new ("$out", {REVERSE_DIMS => 1, MODE=>O_CREAT});
    print "Create \"$out\".\n" if ($verbose);
  } elsif (lc($r) eq "m") {
    $ncf = PDL::NetCDF->new ("$out", {REVERSE_DIMS => 1, MODE=>O_RDWR});
    print "Open \"$out\".\n" if ($verbose);
  } else {
    exit;
  }
} elsif (-e $out && ! -w $out) {
  die("file \"$out\" not writable.\n");
} else {
  $ncf = PDL::NetCDF->new ("$out", {REVERSE_DIMS => 1, MODE=>O_CREAT});
  print "Create \"$out\".\n" if ($verbose);
}
if ($grid) {
  $ncf->put('lon', ['lon'], $lon);
  $ncf->putatt('longitude', 'long_name', 'lon');
  $ncf->putatt('degree_east', 'units', 'lon');
  $ncf->put('lat', ['lat'], $lat);
  $ncf->putatt('latitude', 'long_name', 'lat');
  $ncf->putatt('degree_north', 'units', 'lat');
}
$ncf->putatt(gmctime(), 'created_at');
$ncf->putatt("$pcall", 'created_with');
$ncf->putatt("$ENV{USER}", 'created_by');

#############################
### open the ascii file
### first column is interpreted as longitude,
### second is latitude,
### third one is year
### and the following columns are interpreted either as one data field perl column
### or monthly data if --month is given.

open(LPJ, "< $in");
my @lines = <LPJ>;
close(LPJ);

my $header = shift(@lines); # uncomment for CRU data without header
my @header = split(" ", $header);
my $nlines = @lines;

# initialize the time counter
my $starttime = time();

###########################################
### process data if a grid is specified ###
###########################################
if ($grid) {
  ####################
  ### monthly data ###
  ####################
  if ($month) {
    my $oy    = 999999;  # save old year
    my $ny    = 0;       # number of years
    my $init  = 0;       # time record saved after first point
    my $ip    = 0;       # number of grid points
    my $iline = 0;

    my $ilon=0;
    my $ilat=0;

    my @dataref;

    $time = null();

    foreach my $line (@lines) {
      chomp($line);
      my @indata  = split(" ", $line);
      $year = $indata[2] if (!$year);
      $ndata = @indata;

      die ("Number of columns incorrect. Should be 15 is $ndata.\n") if ($ndata != 15);

      # commented out -> no leap year
      #if (($indata[2]%4 == 0 && $indata[2]%100 != 0) || $indata[2]%400 == 0) {
      #  $dpm->set(1,29);
      #} else {
      #  $dpm->set(1,28);
      #}

      # too big for one PDL, create an array holding the references of a pdl for every year
      # -> takes long to save the data
      #
      # $indata[2] is the simulated year + 1401 to give 1901 for a 500 year spinup period.
      # $oy is the year of the previous data line in the text file (set at the end of the loop).
      if ($oy > $indata[2]) {
        # first line of data
        if (!$iline) {
          push(@dataref, \zeroes($lon->nelem, $lat->nelem, 12));
          ${$dataref[$ny]} .= NaN;
          $time = $time->append($dpm->cumusumover - 1);
        }

        # inititialize the indices for the lon/lat position
        # substract res for data with centered gridcells (Sheffield/Princeton)
        $ilon=($indata[0]-$west)/$xres;  # - $xres;
        $ilat=($indata[1]-$south)/$yres; # + $yres; # also below for invertlat 
        $ilat=($north-$south)/$yres - ($indata[1]-$south)/$yres if($invertlat);
        if ($centered) {
          $ilon -= $xres;
          $ilat += $yres;
        }

        $ny=0;
        $ip++;
      } else {
        $ny++;
        $time = $time->append($dpm->cumusumover+$time->at(-1)) if ($ip==1);

        # create a new anonymous pdl as array element for each year,
        # while the first point is processed.
        if ($ip==1) {
          push(@dataref, \zeroes($lon->nelem, $lat->nelem, 12));
          ${$dataref[$ny]} .= NaN;
        }
      }
      $outdata = pdl(@indata[3 .. $ndata-1]);
      ${$dataref[$ny]}->slice("$ilon,$ilat,:")->clump(3) .= PDL::double($outdata);      

      $oy = $indata[2];

      # some useless counters for verbose output
      $iline++;
      my $etc = time()-$starttime;
      my $etr = $etc/($iline/$nlines) - $etc;
      my @timing  = (int($etc/3600), 
                     int($etc/60) - int($etc/3600)*60, 
                     int($etc) - int($etc/60)*60,
                     int($etr/3600), 
                     int($etr/60) - int($etr/3600)*60, 
                     int($etr) - int($etr/60)*60
          );
      printf("\rRead lines processed: %5.1f%% (%i/%i); time: %02i:%02i:%02i ETC, %02i:%02i:%02i ETR",
             $iline/$nlines*100,$iline,$nlines,
             $timing[0],$timing[1],$timing[2],$timing[3],$timing[4],$timing[5])
          if ($verbose);      
    } 
    # end loop over text file
    print "\n" if ($verbose);

    $ncf->putslice('time', ['time'], [PDL::NetCDF::NC_UNLIMITED()], [0], [($ny+1)*12], $time);
    $ncf->putatt(sprintf('day since %04i-01-01 00:00:00', $year), 'units', 'time');
    $ncf->putatt('gregorian', 'calendar', 'time');
    $ncf->putatt('time', 'long_name', 'time');
  
    # reinitialize the time counter
    my $starttime = time();

    my $iy=0;
    foreach $outdata (@dataref) {
      $ncf->putslice('data', ['lon','lat','time'], [$lon->nelem, $lat->nelem, PDL::NetCDF::NC_UNLIMITED()], 
                     [0,0,$iy], [$lon->nelem, $lat->nelem,12], ${$outdata});
      $iy+=12;

      # some useless counters for verbose output
      my $etc = time()-$starttime;
      my $etr = $etc/($iy/($ny*12)) - $etc;
      my @timing  = (int($etc/3600), 
                     int($etc/60) - int($etc/3600)*60, 
                     int($etc) - int($etc/60)*60,
                     int($etr/3600), 
                     int($etr/60) - int($etr/3600)*60, 
                     int($etr) - int($etr/60)*60
          );
      printf("\rSave data (months): %i/%i time: %02i:%02i:%02i ETC, %02i:%02i:%02i ETR",
             $iy,($ny*12), 
             $timing[0],$timing[1],$timing[2],$timing[3],$timing[4],$timing[5])
          if ($verbose);      
    }
    print "\n" if ($verbose);

  ###################
  ### annual data ###
  ###################
  } else {
    my $oy    = -999999; # save old year
    my $ny    = 0;       # number of years
    my $init  = 0;       # time record saved after first point
    my $ip    = 0;
    my $iline = 0;

    my $ilon=0;
    my $ilat=0;

    my @dataref;

    foreach my $line (@lines) {
      chomp($line);
      my @indata  = split(" ", $line);
      $ndata = @indata;

      # new gridpoint (starting with the 2nd one)
      if ($oy > $indata[2]){
        # save the data of the previous point
        for my $i (3 .. $ndata-1) {
          # too big for one PDL, create an array holding the references of $ndata-3 PDLs ("anonymous PDLs")
          if (!$init) {
            $dataref[$i-3]=\zeroes($lon->nelem, $lat->nelem, $time->nelem);
            ${$dataref[$i-3]} .= NaN;
          }
          ${$dataref[$i-3]}->slice("$ilon,$ilat,:")->clump(3) .= PDL::double($outdata->mslice(X,$i-3));
        }

        $ny = 0;
        $init++;
      }
      # new gridpoint (starting with the 1st one)
      # substract/add resolution for centered grid point (Sheffield/Princeton)
      if ($ny == 0) {
        $ip++;
        $ilon=($indata[0]-$west)/$xres;# -$xres;
        $ilat=($indata[1]-$south)/$yres; # + $yres; # also below for invertlat 
        $ilat=($north-$south)/$yres - ($indata[1]-$south)/$yres if($invertlat);

        if ($centered) {
          $ilon -= $xres;
          $ilat += $yres;
        }

        $outdata = pdl(@indata[3 .. $ndata-1])->dummy(0);
      } else {
        $outdata = $outdata->append(pdl(@indata[3 .. $ndata-1])->dummy(0));
      }

      $year = long($indata[2]) if (!$year && $init==1 && $ny==0);

      $time = $time->append(long($ny)) if (!$init);
      $ncf->putslice('time', ['time'], [PDL::NetCDF::NC_UNLIMITED()], [0], [$time->nelem], $time*365+364) if ($init==1 && $ny==0);
      $ncf->putatt(sprintf('days since %04i-01-01 00:00:00',$year), 'units', 'time') if ($init==1 && $ny==0);
      $ncf->putatt('noleap', 'calendar', 'time') if ($init==1 && $ny==0);
      $ncf->putatt('time', 'long_name', 'time') if ($init==1 && $ny==0);

      $oy = $indata[2];
      $ny++;

      $iline++;
      # some useless counters for verbose output
      my $etc = time()-$starttime;
      my $etr = $etc/($iline/$nlines) - $etc;
      my @timing  = (int($etc/3600), 
                     int($etc/60) - int($etc/3600)*60, 
                     int($etc) - int($etc/60)*60,
                     int($etr/3600), 
                     int($etr/60) - int($etr/3600)*60, 
                     int($etr) - int($etr/60)*60
          );
      printf("\rLines processed: %5.1f%% (%i/%i); gp: %i time: %02i:%02i:%02i ETC, %02i:%02i:%02i ETR",
             $iline/$nlines*100,$iline,$nlines, $ip, 
             $timing[0],$timing[1],$timing[2],$timing[3],$timing[4],$timing[5])
          if ($verbose);
    }
    print "\n" if ($verbose);
    for my $i (3 .. $ndata-1) {
      # save the data
      $ncf->putslice("$header[$i]", ['lon','lat','time'], 
		     [$lon->nelem, $lat->nelem, PDL::NetCDF::NC_UNLIMITED()],
		     [0,0,0], [$lon->nelem, $lat->nelem, $time->nelem],
		     PDL::float(${$dataref[$i-3]}));
      $ncf->putatt($unit, 'units', "$header[$i]");
      printf("\r%s (%i/%i) saved       ", $header[$i], $i-2, $ndata-3) if ($verbose);

    }
  }
} # end if ($grid)

print "\n" if ($verbose);
exit;

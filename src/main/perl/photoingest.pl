#!/usr/bin/perl
#
# Copyright 2010 David Hay
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

use strict;
use warnings;
use Image::ExifTool qw(:Public);
use File::Spec::Functions qw(:ALL);
use File::Find;
use File::Basename;
use File::Copy;
use File::Path qw(mkpath);
use File::Compare;
use File::stat;
use Getopt::Long;
use Pod::Usage;

# Optionally import libs for dealing with Windows Recycle Bin
if ($^O =~ /MSWin32/i || $^O =~ /cygwin/i) {
  eval { 
    require Win32::FileOp;
  };
  if (! $@) {
    Win32::FileOp->import( qw(Recycle) );
  }
}

my $version = "__BUILD_VERSION__";
my $copyright = "Copyright (c) 2010 David Hay";

my @rawExtensions = (
  "nef", "nrw",        # Nikon
  "crw", "cr2",        # Canon
  "orf",               # Olympus
  "arw", "srf", "sr2", # Sony
  "3fr",               # Hasselblad
  "bay",               # Casio
  "cap", "iiq", "eip", # Phase One
  "dcs", "dcr", "drf", "k25", "kdc", # Kodak
  "dng",               # Adobe, Lecia, Hasselblad, Pentax, Ricoh, Samsung
  "erf",               # Epson
  "fff",               # Imacon
  "mef",               # Mamiya
  "mos",               # Leaf
  "mrw",               # Minolta
  "ptx", "pef",        # Pentax
  "pxn",               # Logitech
  "r3d",               # Red
  "raf",               # Fuji
  "raw", "rw2",        # Panasonic
  "raw", "rw1",        # Leica
  "rwz",               # Rawzor
  "x3f",               # Sigma
);

my @extraExtensions = (
  "jpg",
  "tif",
  "tiff",
  "jpeg",
  "png",
  "gif",
  "xmp",
);

my $sourceDir;
my @rawPatterns = ( '\.(?i:' . join('|', @rawExtensions) . ')$');
my @includePatterns = (
  '\.(?i:' . join('|', @extraExtensions) . ')$',
  @rawPatterns
);
my @destDirs;
my $filenamePattern = 'img_[%yyyy][%MM][%dd]_[%FILE]';
my $test;
my $toDNG = 1;
my $keepRAW = 0;
my $dngOpts = '-c -p2 -d [%OUTPUT_DIR] -o [%OUTPUT_FILE] [%INPUT]';
my $verbose;
my $historyFile = "photoingest-history.txt";
my $overwrite;
my $newFiles;
my $dngConvert;
my $rawJpgExtract = 1;
my $verify = 1;

my $error = 0;


#===============================================================================

sub createFilename {
  my ($file) = @_;

  my ($base, $dir, $ext) = fileparse($file, qr/.[^.]*/);

  # Get the EXIF timestamp from the file.
  # If it doesn't have one, use today's date.
  my $exifTool = new Image::ExifTool;
  my $info = $exifTool->ImageInfo($file, 'DateTimeOriginal');
  my $exifDate = $$info{'DateTimeOriginal'};
  my ($year, $month, $day, $hour, $minute, $second);
  if ($exifDate) {
    ($year, $month, $day, $hour, $minute, $second) = split(/[ :Z]/, $exifDate);
  }
  else {
    print "No EXIF DateTimeOriginal field found for $file\n" if $verbose;
 
    my $fs = stat($file);
    ($second,$minute,$hour,$day,$month,$year) = localtime($fs->mtime);
    $year += 1900;
    $month++;
  }

  my $yyyy = sprintf("%04d", $year);
  my $yy   = sprintf("%02d", ($year < 2000 ? $year - 1900 : $year - 2000));
  my $MM   = sprintf("%02d", $month);
  my $dd   = sprintf("%02d", $day);
  my $hh   = sprintf("%02d", $hour);
  my $mm   = sprintf("%02d", $minute);
  my $ss   = sprintf("%02d", $second);

  my $pattern = '';
  for (split(/[\[\]]/, $filenamePattern)) {
    SWITCH: {
      if (/^%yyyy$/) { $pattern .= $yyyy; last SWITCH; }
      if (/^%yy$/)   { $pattern .= $yy;   last SWITCH; }
      if (/^%MM$/)   { $pattern .= $MM;   last SWITCH; }
      if (/^%dd$/)   { $pattern .= $dd;   last SWITCH; }
      if (/^%hh$/)   { $pattern .= $hh;   last SWITCH; }
      if (/^%mm$/)   { $pattern .= $mm;   last SWITCH; }
      if (/^%ss$/)   { $pattern .= $ss;   last SWITCH; }
      if (/^%FILE$/) { $pattern .= $base; last SWITCH; }
      if (1)         { $pattern .= $_;    last SWITCH; }
    }
  }

  $pattern .= $ext;

  return $pattern;
}

#-------------------------------------------------------------------------------

sub verifyFile {
  my ($origFile, $newFile) = @_;
  print "Verifying $newFile\n" if $verbose;
  return (compare($origFile, $newFile) == 0);
}

#-------------------------------------------------------------------------------

sub resolveFilenameConflicts {
  my ($filename) = @_;
  my $index = 0;
  my $conflict=0;
  my ($f, $d, $ext) = fileparse($filename, qr/.[^.]*/);
  do {
    $conflict = 0;
    my $first = 1;
    for my $dest (@destDirs) {
      my $destFile = catfile($dest, $filename);
      my $dngFile = '';
      my $jpgFile = '';
      if (isRaw($filename)) {
	if ($toDNG) {
	  $dngFile = catfile($dest, $d, $f . '.dng');
	}
	if ($rawJpgExtract) {
	  $jpgFile = catfile($dest, $d, $f . '.jpg');
	}
      }
      
      # Find an index that makes the file unique.
      while (-e $destFile 
             || ($dngFile && -e $dngFile) 
	     || ($jpgFile && -e $jpgFile)) {

        print "Conflict found at $destFile\n" if $verbose;

        # Add an index to the filename
	$index++;
        $filename = $f . "-" . $index . $ext;
	$destFile = catfile($dest, $filename);
	if ($dngFile) {
	  $dngFile = catfile($dest, $d, $f . "-" . $index . '.dng');
	}
	if ($jpgFile) {
	  $jpgFile = catfile($dest, $d, $f . "-" . $index . '.jpg');
	}
        
        # If we find a conflict in the first directory but not in the 
        # remaining directories with our new name...we can break out
        # of the do...while loop one iteration early.
        if (!$first) {
	  $conflict = 1;
        }
      }
      $first = 0;
    }
  } while ($conflict);

  return $filename;
}

#-------------------------------------------------------------------------------

sub shouldProcess {
  my ($sourceDir, $file, $history) = @_;

  return 0 unless -f $file;
  
  my $relFile = abs2rel($file, $sourceDir);
  if ($newFiles && exists $history->{$relFile}) {
    print "Ignoring previously processed file: $file\n" if $verbose;
    return 0;
  }

  for my $pattern (@includePatterns) {
     if ( $file =~ /$pattern/ ) {
       return 1;
     }
  }

  return 0
}

#-------------------------------------------------------------------------------

sub isRaw {
  my ($file) = @_;

  for my $pattern (@rawPatterns) {
    if ($file =~ /$pattern/ ) {
      return 1;
    }
  }
  
  return 0;
}

#-------------------------------------------------------------------------------

sub isDNG {
  my ($file) = @_;
  return $file =~ /(?i)\.dng/
}

#-------------------------------------------------------------------------------

sub convertToDNG {
  my ($rawFile, $dngFile) = @_;

  # It's already a DNG or it's not a RAW file
  if (!isRaw($rawFile) || isDNG($rawFile)) { return 0; }

  if (-e $dngFile) {
    trashFile($dngFile);
  }

  print "DNG Convert $rawFile to $dngFile\n" if $verbose;

  my ($dngBase, $dngDir) = fileparse($dngFile);

  if ($^O =~ /cygwin/i) {
    # Need to convert the file paths back to Windows format
    $rawFile = Cygwin::posix_to_win_path($rawFile);
    $dngFile = Cygwin::posix_to_win_path($dngFile);
    $dngDir = Cygwin::posix_to_win_path($dngDir);
  }

  my @opts;
  for my $opt (split(/\s+/, $dngOpts)) {
    $opt =~ s/\[%INPUT\]/$rawFile/gi;
    $opt =~ s/\[%OUTPUT\]/$dngFile/gi;
    $opt =~ s/\[%OUTPUT_DIR\]/$dngDir/gi;
    $opt =~ s/\[%OUTPUT_FILE\]/$dngBase/gi;
    push(@opts, $opt);
  }

  my $command = join(' ', $dngConvert, @opts);
  print "Invoking DNG converter: $command\n" if $verbose;
  if (!$test) {
    system($dngConvert, @opts);
    if ($? != 0) {
      print STDERR "Unable to invoke DNG converter: $command\n";
      return 0;
    }
  }

  return 1;
}

#-------------------------------------------------------------------------------

sub shouldConvertToDNG {
  my ($file) = @_;
  return $dngConvert && isRaw($file) && !isDNG($file);
}

#-------------------------------------------------------------------------------

sub extractRawJpg {
  my ($rawFile, $jpgFile) = @_;

  if (-e $jpgFile) {
    trashFile($jpgFile);
  }

  print "Extracting embedded JPG from $rawFile to $jpgFile\n" if $verbose;

  if (!$test) {
    my $exifTool = new Image::ExifTool;
    $exifTool->Options(Binary=>1);

    my $info = $exifTool->ImageInfo($rawFile, 'JpgFromRaw');
    $exifTool->SetNewValuesFromFile($rawFile, 'exif:*>exif:*');
    $exifTool->WriteInfo($$info{'JpgFromRaw'}, $jpgFile);
    # todo: error checking for file write
  }
  return $jpgFile;
}

#-------------------------------------------------------------------------------

sub processFileList {
  my ($srcDir, $filelist, $history) = @_;
  my $fileCount = @$filelist;

  print "Processing $fileCount files\n";
  
  print "Generating filenames\n";
  my @filenames = ();
  for my $srcFile (@$filelist) {
    my $filename = createFilename($srcFile);
    if (!$overwrite) {
      $filename = resolveFilenameConflicts($filename);
    }
    push(@filenames, $filename);
  }

  print "Copying files\n";
  fileListOperation($filelist, \@filenames, \&copyOriginalToDest);

  if ($rawJpgExtract) {
    print "Extracting JPEGs from RAW files\n";
    fileListOperation($filelist, \@filenames, \&extractJpegToDest);
  }

  if ($toDNG) {
    print "Converting RAW files to DNG\n";
    fileListOperation($filelist, \@filenames, \&convertDNGToDest);
  }

  print "Writing processing history\n";
  if (! $test) {
    my $hf = catfile($srcDir, $historyFile);
    open(HISTORY, ">>$hf") or die "Unable to open $hf for writing\n";
    binmode(HISTORY, ":utf8");

    # Set autoflush on HISTORY
    my $old_fh = select(HISTORY);
    $| = 1;
    select($old_fh);
    
    for my $srcFile (@$filelist) {
      logToHistoryFile($srcDir, $srcFile, $history);
    }

    close(HISTORY);
  }
}

#-------------------------------------------------------------------------------

sub fileListOperation {
  my ($filelist, $filenames, $op) = @_;

  for (my $idx = 0 ; $idx < @$filelist; $idx++) {
    my $srcFile = @$filelist[$idx];
    my $filename = @$filenames[$idx];
    &$op($srcFile, $filename, @destDirs);
  }
}

#-------------------------------------------------------------------------------

sub copyOriginalToDest {
  my ($srcFile, $filename, @destDirs) = @_;
  my ($f, $d, $ext) = fileparse($filename, qr/.[^.]*/);

  # Copy the file to each of the destination directories
  COPY: for my $dest (@destDirs) {
    my $destFile = catfile($dest, $filename);
    if (-e $destFile) {
      trashFile($destFile);
    }
    else {
      # $dest should exist, but the subdirectory under it may not
      # (e.g. because the file pattern is YYYY/MM/FILE)
      my $destDir = catfile($dest, $d);
      if (! -e $destDir) {
        mkpath($destDir);
      }
    }

    print "Copying $srcFile to $destFile\n" if $verbose;
    if (!$test) {
      if (!copy($srcFile, $destFile)) {
	print STDERR "Error copying file: $!\n";
	$error = 1;
	next COPY;
      }
      if ($verify && !verifyFile($srcFile, $destFile)) {
	print STDERR "Verification failed: $destFile\n";
	$error = 1;
      }
    }
  }

}

#-------------------------------------------------------------------------------

sub extractJpegToDest {
  my ($srcFile, $filename, @destDirs) = @_;
  my ($f, $d, $ext) = fileparse($filename, qr/.[^.]*/);

  # Extract JPG from Raw
  if ($rawJpgExtract && isRaw($srcFile)) {
    my $jpgFilename = catfile($d, $f . '.jpg');
    my $first = 1;
    my $jpgFile;
    JPG: for my $dest (@destDirs) {
      my $rawFile = catfile($dest, $filename);
      if ($first) {
        $first = 0;
        $jpgFile = catfile($dest, $jpgFilename);
	if (!extractRawJpg($rawFile, $jpgFile)) {
	  $error = 1;
	  last JPG;
	}
      }
      else {
        my $destFile = catfile($dest, $jpgFilename);
	print "Copying extracted JPEG $jpgFile to $destFile\n" if $verbose;
	if (!$test) {
	  if (!copy($jpgFile, $destFile)) {
	    print STDERR "Unable to copy JPEG file: $!\n";
	    $error = 1;
	    next JPG;
	  }
	}
      }
    }
  }
}

#-------------------------------------------------------------------------------

sub convertDNGToDest {
  my ($srcFile, $filename, @destDirs) = @_;
  my ($f, $d, $ext) = fileparse($filename, qr/.[^.]*/);

  # Convert to DNG
  if (shouldConvertToDNG($srcFile)) {
    my $dngFilename = catfile($d, $f . '.dng');

    my $first = 1;
    my $dngFile;
    DNG: for my $dest (@destDirs) {
      my $rawFile = catfile($dest, $filename);
      if ($first) {
	$first = 0;
        $dngFile = catfile($dest, $dngFilename);
	if (!convertToDNG($rawFile, $dngFile)) {
	  $error = 1;
	  last DNG;
	}
      }
      else {
	my $destFile = catfile($dest, $dngFilename);
	print "Copying converted DNG $dngFile to $destFile\n" if $verbose;
	if (!$test) {
	  if (!copy($dngFile, $destFile)) {
	    print STDERR "Unable to copy DNG file: $!\n";
	    $error = 1;
	    next DNG;
	  }
	}
      }
      if (!$keepRAW) {
        trashFile($rawFile);
      }
    }
  }
}

#-------------------------------------------------------------------------------

sub trashFile {
  my ($file) = @_;
  print "Moving $file to trash\n" if $verbose;

  return if $test;

  if ($^O =~ /(?i:MSWin32|cygwin)/) {
    Recycle($file);
  }
  elsif ($^O =~ /(?i)darwin/) {
    move($file, catfile($ENV{HOME}, ".Trash"));
  }
  else {
    # todo: move to trash dir based on ENV variable
    system("rm", $file);
  }
}

#-------------------------------------------------------------------------------

sub logToHistoryFile {
  my ($dir, $file, $history) = @_;
  if (!$test) {
    my $hentry = abs2rel($file, $dir);
    print HISTORY "$hentry\n" unless exists $history->{$hentry};
  }
}

#-------------------------------------------------------------------------------

sub readHistory {
  my ($historyFile) = @_;

  print "Reading history of previous imports\n";

  my %history = ();
  open(HISTORY, "<$historyFile") or return;
  binmode(HISTORY, ":utf8");
  while (<HISTORY>) {
    chomp;
    $history{$_} = 1;
  }
  close(HISTORY);
  return \%history
}

#-------------------------------------------------------------------------------

sub processSourceDirectory {
  my ($dir) = @_;

  print "Scanning $dir \n";

  my $hf = catfile($dir, $historyFile);

  my $history = readHistory($hf);
  my @dirlist = ($dir);
  my @filelist = ();
  find(sub { 
         my $srcFile = $File::Find::name;
	 if (shouldProcess($dir, $srcFile, $history)) {
	   push(@filelist, $srcFile); 
	 }
       },
       @dirlist); 

  processFileList($dir, \@filelist, $history);

}

#-------------------------------------------------------------------------------

sub displayVersion {
  my $cmd = basename($0);
  print "Photoingest version $version. $copyright\n";
}

#===============================================================================

my $help;
my $showVersion;

# Parse the command line
Getopt::Long::Configure ("bundling");
GetOptions("file-pattern=s" => \$filenamePattern,
           "dry-run|test"   => \$test,
           "dng!"           => \$toDNG,
           "dng-converter"  => \$dngConvert,
           "dng-options"    => \$dngOpts,
	   "dng-keep-raw!"  => \$keepRAW,
           "jpg-extract!"   => \$rawJpgExtract,
           "verbose"        => \$verbose,
	   "verify!"        => \$verify,
           "overwrite!"     => \$overwrite,
	   "new!"           => \$newFiles,
	   "version"        => \$showVersion,
           "help"           => \$help)
  or pod2usage(2);

pod2usage({ -exitval => 1,
            -verbose => $verbose ? 1 : 0 } ) if $help;

if ($showVersion) {
  displayVersion($version);
  exit;
}

print "Test mode enabled, no files will be copied or modified\n" if $test;

# First non-option is the source directory to process
$sourceDir = shift or die "Source directory not specified\n";
die "Source directory $sourceDir does not exist\n" if (! -d $sourceDir);
die "Unable to read from $sourceDir\n" if (! -r $sourceDir);

# Remaining options are the destination directories to copy files to
@destDirs = @ARGV;
die "Destination directories not specified\n" if (!@destDirs);
for my $dest (@destDirs) {
  die "Destination directory $dest does not exist\n" if (! -d $dest);
  die "Unable to write to $dest\n" if (! -w $dest);
}

# Convert relative source and dest paths to absolute. Makes everything easier.
$sourceDir = rel2abs($sourceDir);
@destDirs = map {rel2abs($_);} @destDirs;

# check DNG Options
die "No DNG options provided in --dng-options\n" if $toDNG && !$dngOpts;

if ($toDNG && !$dngConvert) {
  if ( $^O =~ /darwin/i ) {
    $dngConvert = 
     '/Applications/Adobe DNG Converter.app/Contents/MacOS/Adobe DNG Converter';
  }
  elsif ($^O =~ /(?i:MSWin32|cygwin)/) {
    $dngConvert = 'C:\Program Files\Adobe\Adobe DNG Converter.exe';
    if ($^O =~ /cygwin/i) {
      $dngConvert = Cygwin::win_to_posix_path($dngConvert);
    }
  }
  else {
    die "Unable to automatically determine DNG converter for OS $^O. Specify one with --dng-converter\n";
  }

  # See if the DNG converter even exists.
  die "$dngConvert cannot be executed\n" unless -x $dngConvert;
}

processSourceDirectory($sourceDir);

if ($error) {
  die "There were errors while processing $sourceDir\n";
}

__END__

=head1 SYNOPSIS

photoingest.pl [options] SOURCE DESTINATION [DESTINATION...]

  --help             Brief help message (adding --verbose shows more)
  --file-pattern     Pattern to use for renaming files.
  --dng, --no-dng    Convert (don't convert) RAW files to DNG
  --dng-options      Options to pass to the DNG converter
  --dng-convert      Path to the DNG converter executable
  --dng-keep-raw     If converting to DNG, copy the original RAW file too.
  --no-dng-keep-raw  Don't keep the original RAW file after conversion to DNG
  --dry-run, --test  Don't copy or convert files, just print the operations
  --jpg-extract      Extract embedded JPG images from RAW files.
  --no-jpg-extract   Do not extract embedded JPG images from RAW files.
  --new              Only includes files added since the last import
  --no-new           Copy everything from the source directory
  --overwrite        Replace files in the destination (move old to Trash)
  --no-overwrite     Do not overwrite files in the destination
  --verbose          Display additional logging.
  --verify           Verify the files copied from the source directory.
  --no-verify        Do not verify that files were copied successfully.
  --overwrite        Overwrite existing files in the destination

=head1 DESCRIPTION

Scans files in the the SOURCE directory any any sub directories for image
files and copies them, with some optional processing, to each of the given
DESTINATION directories.

=head1 OPTIONS

=over 8

=item B<--help>

Print a brief help message and exits.  If the --verbose option is also
provided, extended help information is provided about each of the options.

=item B<--file-pattern> PATTERN

The pattern to use for renaming files during copy.  Defaults to
'img_[%yyyy][%MM][%dd]_[%FILE]' The appropriate extension for the file is
automatically appended. (e.g. don't include the extension in the pattern) The
pattern may contain placeholder values indicated by [%placeholder]. The
following placeholder values are supported.  Date based placeholder values are
based on the EXIF data.  If no EXIF date is found, the last modified date of
the file is used.

=over 8

=item [%yyyy] - Four digit year

=item [%yy]   - Two digit year

=item [%MM]   - Month

=item [%dd]   - Day

=item [%hh]   - Hour (24-hour time)

=item [%mm]   - Minute

=item [%ss]   - Second

=item [%FILE] - Base name of the original file (without the extension).

=back

For example, if the input file is DSC_1234.jpg and was shot on September 23,
2010, the default pattern would result in a filename of
img_20100923_DSC_1234.jpg

=item B<--dng>, B<--no-dng>

Convert (don't convert) any RAW files that aren't already in DNG format to DNG.
(default: --dng)

=item B<--dng-converter>

This is the path to the DNG conversion command.  If not specified, the Adobe
DNG Converter is looked for in standard installation locations.

=item B<--dng-keep-raw>, B<--no-dng-keep-raw>

If converting RAW files to DNG, specifying this option indicates that the
original RAW file should be copied to the destination along with the DNG file.
(default: --no-dng-keep-raw)

=item B<--dng-options>

The options to pass to the DNG command.  Defaults to the following (assuming
the Adobe DNG Converter):

=over 8

-d [%OUTPUT_DIR] -o [%OUTPUT_FILE] [%INPUT]

=back

The elements in square brackets are replaced with elements from the currently
processed file:

=over 8

=item [%INPUT]

The fully qualified path to the file currently being processed.

=item [%OUTPUT]

The fully qualified path to the destination DNG file

=item [%OUTPUT_DIR]

The directory of the destination DNG file

=item [%OUTPUT_FILE]

The name of the file, without the leading directory path, of the DNG file

=back

=item B<--dry-run>, B<--test>

Doesn't copy any files but prints out log messages indicating what operations
would have been performed.

=item B<--jpg-extract>, B<--no-jpg-extract>

When processing RAW files, extract the embedded JPG file from the RAW file.
The extracted file will have the same name as the RAW file except for the
extension (which will be changed to ".jpg")

=item B<--new>

Only process files that are new since the last processing.  This is determined
by consulting the photoingest-history.txt file that is created in the source
directory during each import.

=item B<--no-new>

Copy all files from the source directory, regardless of whether they've been
imported previously.

=item B<--overwrite>

After the name of the destination file is determined, if a file exists in any
of the destination directories with the same name, the file will be overwritten
with the version (possibly converted) from the source directory.

=item B<--no-overwrite>

After the name of the destination file is determined, if a file exists in any
of the destination directories with the same name, the filename will have a
sequence number added to the end of the filename (before the extension) in
order to make the filename unique.

=item B<--verbose>

Print additional information about what is happening during the import process

=item B<--verify>, B<--no-verify>

Verify (don't verify) that the contents of the file copied to the destination
directory matches the original file from the source directory. 
(default: --verify)

=item B<--version> 

Displays the version of this program

=back

=cut


name: Build Debian ISO
on: [workflow_dispatch] # Allows you to start it manually with one click

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout Code
        uses: actions/checkout@v4

      - name: Install Debian Build Tools
        run: |
          sudo apt update
          sudo apt install -y debootstrap live-build squashfs-tools xorriso grub-pc-bin mtools binutils ca-certificates

      - name: Make Script Executable & Run
        run: |
          chmod +x build.sh
          sudo ./build.sh

      - name: Upload Finished ISO
        uses: actions/upload-artifact@v4
        with:
          name: debian-gnome-iso
          path: ./*.iso # This looks for any file ending in .iso in the folder

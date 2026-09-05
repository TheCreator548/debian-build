name: Build novaOS ISO

on:
  workflow_dispatch:
    inputs:
      distro:
        description: "Base distro"
        required: false
        default: "ubuntu"
        type: choice
        options: [ubuntu, debian]
      codename:
        description: "Release codename (blank = default: noble/bookworm)"
        required: false
        default: ""
      os_name:
        description: "OS name baked into the ISO"
        required: false
        default: "novaOS"

jobs:
  build:
    runs-on: ubuntu-latest
    # Full GNOME live-build can take a while and eat disk space —
    # give it room on both fronts.
    timeout-minutes: 300
    steps:
      - name: Check out repo
        uses: actions/checkout@v4

      - name: Free up disk space
        run: |
          sudo rm -rf /usr/share/dotnet /usr/local/lib/android /opt/ghc
          sudo apt-get clean
          df -h

      - name: Make build script executable
        run: chmod +x ./ci-build-iso.sh

      - name: Build ISO
        id: build
        run: ./ci-build-iso.sh
        env:
          DISTRO: ${{ inputs.distro }}
          CODENAME: ${{ inputs.codename }}
          OS_NAME: ${{ inputs.os_name }}

      - name: Upload ISO artifact
        uses: actions/upload-artifact@v4
        with:
          name: ${{ inputs.os_name }}-iso
          path: artifacts/*.iso
          retention-days: 14

      - name: Summary
        if: always()
        run: |
          echo "### novaOS build" >> "$GITHUB_STEP_SUMMARY"
          echo "- Distro: ${{ inputs.distro }} ${{ inputs.codename }}" >> "$GITHUB_STEP_SUMMARY"
          echo "- ISO: ${{ steps.build.outputs.iso_path }}" >> "$GITHUB_STEP_SUMMARY"

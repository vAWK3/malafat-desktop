#!/bin/bash

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# File paths
PACKAGE_JSON="package.json"
TAURI_CONF="src-tauri/tauri.conf.json"
CARGO_TOML="src-tauri/Cargo.toml"
RELEASE_DIR="release"

# GitHub repository info (auto-detected from git remote)
GITHUB_OWNER=""
GITHUB_REPO=""

# --- Release secrets (mac notarization + updater signing) ---
RELEASE_ENV_FILE="./release.env"
UPDATER_PRIVATE_KEY_FILE="${TAURI_SIGNING_PRIVATE_KEY_PATH:-$HOME/.tauri/malafat.key}"

load_release_env() {
    # Load env vars from local file (not committed)
    if [[ -f "$RELEASE_ENV_FILE" ]]; then
        # shellcheck disable=SC1090
        source "$RELEASE_ENV_FILE"
        echo -e "  ${GREEN}✓${NC} Loaded release env from ${CYAN}$RELEASE_ENV_FILE${NC}"
    else
        echo -e "  ${YELLOW}⚠${NC} No ${CYAN}$RELEASE_ENV_FILE${NC} found. mac notarization may fail."
        echo -e "    Create it with APPLE_SIGNING_IDENTITY / APPLE_ID / APPLE_TEAM_ID / APPLE_PASSWORD."
        echo -e "    Also add TAURI_SIGNING_PRIVATE_KEY and TAURI_SIGNING_PRIVATE_KEY_PASSWORD for updates."
    fi
}

require_release_env() {
    local missing=()

    [[ -z "${APPLE_SIGNING_IDENTITY:-}" ]] && missing+=("APPLE_SIGNING_IDENTITY")
    [[ -z "${APPLE_ID:-}" ]] && missing+=("APPLE_ID")
    [[ -z "${APPLE_TEAM_ID:-}" ]] && missing+=("APPLE_TEAM_ID")
    [[ -z "${APPLE_PASSWORD:-}" ]] && missing+=("APPLE_PASSWORD")

    if (( ${#missing[@]} > 0 )); then
        echo -e "${RED}Error: Missing required mac notarization env vars:${NC} ${missing[*]}"
        echo ""
        echo -e "${YELLOW}Fix:${NC} create ${CYAN}$RELEASE_ENV_FILE${NC} with:"
        echo -e "  export APPLE_SIGNING_IDENTITY='Developer ID Application: Your Company (TEAMID)'"
        echo -e "  export APPLE_ID='you@example.com'"
        echo -e "  export APPLE_TEAM_ID='TEAMID'"
        echo -e "  export APPLE_PASSWORD='app-specific-password'"
        echo ""
        exit 1
    fi
}

# Check if updater signing is configured
check_updater_signing() {
    if [[ -z "${TAURI_SIGNING_PRIVATE_KEY:-}" ]]; then
        echo -e "  ${YELLOW}⚠${NC} TAURI_SIGNING_PRIVATE_KEY not set - auto-update signing disabled"
        echo -e "    To enable: add TAURI_SIGNING_PRIVATE_KEY and TAURI_SIGNING_PRIVATE_KEY_PASSWORD to release.env"
        return 1
    fi
    echo -e "  ${GREEN}✓${NC} Updater signing key configured"
    return 0
}

# Get current version from package.json
get_version() {
    grep '"version"' "$PACKAGE_JSON" | head -1 | sed 's/.*"version": "\([^"]*\)".*/\1/'
}

# Increment patch version
increment_patch() {
    local version=$1
    local major=$(echo "$version" | cut -d. -f1)
    local minor=$(echo "$version" | cut -d. -f2)
    local patch=$(echo "$version" | cut -d. -f3)
    local new_patch=$((patch + 1))
    echo "$major.$minor.$new_patch"
}

# Update version in all config files
update_version() {
    local new_version=$1

    echo -e "${BLUE}Updating version to ${GREEN}$new_version${NC}"

    # Update package.json
    if [[ "$OSTYPE" == "darwin"* ]]; then
        sed -i '' "s/\"version\": \"[^\"]*\"/\"version\": \"$new_version\"/" "$PACKAGE_JSON"
    else
        sed -i "s/\"version\": \"[^\"]*\"/\"version\": \"$new_version\"/" "$PACKAGE_JSON"
    fi

    # Update tauri.conf.json
    if [[ "$OSTYPE" == "darwin"* ]]; then
        sed -i '' "s/\"version\": \"[^\"]*\"/\"version\": \"$new_version\"/" "$TAURI_CONF"
    else
        sed -i "s/\"version\": \"[^\"]*\"/\"version\": \"$new_version\"/" "$TAURI_CONF"
    fi

    # Update Cargo.toml (only the package version, not dependencies)
    if [[ "$OSTYPE" == "darwin"* ]]; then
        sed -i '' "s/^version = \"[^\"]*\"/version = \"$new_version\"/" "$CARGO_TOML"
    else
        sed -i "s/^version = \"[^\"]*\"/version = \"$new_version\"/" "$CARGO_TOML"
    fi

    echo -e "${GREEN}Version updated in all config files${NC}"
}

# Detect GitHub owner and repo from git remote
detect_github_repo() {
    local remote_url
    remote_url=$(git remote get-url origin 2>/dev/null || echo "")

    if [[ -z "$remote_url" ]]; then
        echo -e "${RED}Error: No git remote 'origin' found${NC}"
        return 1
    fi

    # Parse GitHub URL (supports both HTTPS and SSH formats)
    # HTTPS: https://github.com/owner/repo.git
    # SSH: git@github.com:owner/repo.git
    if [[ "$remote_url" =~ github\.com[:/]([^/]+)/([^/.]+)(\.git)?$ ]]; then
        GITHUB_OWNER="${BASH_REMATCH[1]}"
        GITHUB_REPO="${BASH_REMATCH[2]}"
        echo -e "${CYAN}Detected repository: ${BOLD}$GITHUB_OWNER/$GITHUB_REPO${NC}"
        return 0
    else
        echo -e "${RED}Error: Could not parse GitHub URL from remote: $remote_url${NC}"
        return 1
    fi
}

# Check prerequisites for GitHub release
check_release_prerequisites() {
    echo -e "${BLUE}Checking release prerequisites...${NC}"
    echo ""

    # Check if gh CLI is installed
    if ! command -v gh &> /dev/null; then
        echo -e "${RED}Error: GitHub CLI (gh) is not installed${NC}"
        echo ""
        echo -e "${YELLOW}Install it with:${NC}"
        echo -e "  ${CYAN}brew install gh${NC}"
        echo ""
        echo -e "Then authenticate with:"
        echo -e "  ${CYAN}gh auth login${NC}"
        exit 1
    fi
    echo -e "  ${GREEN}✓${NC} GitHub CLI (gh) installed"

    # Check if gh is authenticated
    if ! gh auth status &> /dev/null; then
        echo -e "${RED}Error: GitHub CLI is not authenticated${NC}"
        echo ""
        echo -e "${YELLOW}Authenticate with:${NC}"
        echo -e "  ${CYAN}gh auth login${NC}"
        exit 1
    fi
    echo -e "  ${GREEN}✓${NC} GitHub CLI authenticated"

    # Detect GitHub repository
    if ! detect_github_repo; then
        exit 1
    fi
    echo -e "  ${GREEN}✓${NC} Repository detected"

    # Check git working tree status (warn but don't fail)
    if [[ -n $(git status --porcelain 2>/dev/null) ]]; then
        echo -e "  ${YELLOW}⚠${NC} Working tree has uncommitted changes (will be committed)"
    else
        echo -e "  ${GREEN}✓${NC} Working tree clean"
    fi

    echo ""
    echo -e "${GREEN}All prerequisites satisfied${NC}"
    echo ""
}

# Tag and push to GitHub
tag_and_push() {
  local version=$1
  local tag="v$version"

  echo -e "${BLUE}Preparing git commit, tag and push...${NC}"

  # 1) Commit the version/config changes (so the tag points to the right commit)
  git add "$PACKAGE_JSON" "$TAURI_CONF" "$CARGO_TOML" || true

  if [[ -n $(git status --porcelain 2>/dev/null) ]]; then
    git commit -m "Release $tag" || true
    echo -e "  ${GREEN}✓${NC} Committed release changes"
  else
    echo -e "  ${YELLOW}→${NC} No changes to commit"
  fi

  # Push main so origin has the commit your tag should reference
  git push origin main
  echo -e "  ${GREEN}✓${NC} Pushed main"

  # Always refresh tags from origin (covers "remote exists, local missing")
  git fetch --tags origin >/dev/null 2>&1 || true

  local local_exists=false
  local remote_exists=false

  if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
    local_exists=true
  fi

  if git ls-remote --exit-code --tags origin "refs/tags/$tag" >/dev/null 2>&1; then
    remote_exists=true
  fi

  if [[ "$remote_exists" == "true" && "$local_exists" == "false" ]]; then
    echo -e "  ${YELLOW}→${NC} Tag '$tag' exists on origin but not locally - fetching..."
    git fetch origin "refs/tags/$tag:refs/tags/$tag"
    echo -e "  ${GREEN}✓${NC} Fetched tag $tag"
    echo ""
    return 0
  fi

  if [[ "$local_exists" == "false" && "$remote_exists" == "false" ]]; then
    echo -e "  ${CYAN}→${NC} Creating tag $tag..."
    git tag -a "$tag" -m "Release $tag"
    local_exists=true
    echo -e "  ${GREEN}✓${NC} Created tag $tag"
  fi

  if [[ "$local_exists" == "true" && "$remote_exists" == "false" ]]; then
    echo -e "  ${CYAN}→${NC} Pushing tag $tag to origin..."
    git push origin "refs/tags/$tag"
    echo -e "  ${GREEN}✓${NC} Pushed tag to origin"
  else
    echo -e "  ${YELLOW}→${NC} Tag '$tag' already exists on origin - not changing it"
  fi

  echo ""
}

# Find the DMG artifact after build
find_dmg_artifact() {
    local dmg_path=""

    echo -e "${BLUE}Locating DMG artifact...${NC}"

    # Search for DMG files in Tauri build output
    # Tauri v2 places DMGs in: src-tauri/target/release/bundle/dmg/
    # For universal builds: src-tauri/target/universal-apple-darwin/release/bundle/dmg/
    local search_paths=(
        "src-tauri/target/universal-apple-darwin/release/bundle/dmg"
        "src-tauri/target/release/bundle/dmg"
    )

    for search_path in "${search_paths[@]}"; do
        if [[ -d "$search_path" ]]; then
            # Find the most recent DMG file
            dmg_path=$(find "$search_path" -name "*.dmg" -type f -print0 2>/dev/null | xargs -0 ls -t 2>/dev/null | head -1)
            if [[ -n "$dmg_path" && -f "$dmg_path" ]]; then
                break
            fi
        fi
    done

    # If not found in specific paths, do a broader search
    if [[ -z "$dmg_path" || ! -f "$dmg_path" ]]; then
        dmg_path=$(find src-tauri/target -name "*.dmg" -type f -print0 2>/dev/null | xargs -0 ls -t 2>/dev/null | head -1)
    fi

    if [[ -z "$dmg_path" || ! -f "$dmg_path" ]]; then
        echo -e "${RED}Error: No DMG file found in build output${NC}"
        echo -e "${YELLOW}Expected location: src-tauri/target/**/bundle/dmg/*.dmg${NC}"
        exit 1
    fi

    # Validate file is non-empty
    if [[ ! -s "$dmg_path" ]]; then
        echo -e "${RED}Error: DMG file is empty: $dmg_path${NC}"
        exit 1
    fi

    echo -e "  ${GREEN}✓${NC} Found: $dmg_path"
    echo "$dmg_path"
}

# Prepare release artifacts
prepare_release_artifacts() {
    local version=$1
    local source_dmg=$2

    echo -e "${BLUE}Preparing release artifacts...${NC}"

    # Create release directory
    mkdir -p "$RELEASE_DIR"

    # Versioned filenames (for archival)
    local versioned_dmg="malafat-v${version}-macos-arm64.dmg"
    local versioned_dmg_path="$RELEASE_DIR/$versioned_dmg"
    local versioned_checksum_file="$RELEASE_DIR/malafat-v${version}-macos-arm64.sha256"

    # Stable filenames (for Netlify redirects)
    local stable_dmg="malafat-macos-arm64.dmg"
    local stable_dmg_path="$RELEASE_DIR/$stable_dmg"
    local stable_checksum_file="$RELEASE_DIR/malafat-macos-arm64.dmg.sha256"

    # Copy DMG to versioned path
    cp "$source_dmg" "$versioned_dmg_path"
    echo -e "  ${GREEN}✓${NC} Copied DMG to $versioned_dmg_path"

    # Copy DMG to stable path
    cp "$source_dmg" "$stable_dmg_path"
    echo -e "  ${GREEN}✓${NC} Copied DMG to $stable_dmg_path (stable)"

    # Generate SHA256 checksum
    local checksum
    checksum=$(shasum -a 256 "$versioned_dmg_path" | awk '{print $1}')
    echo "$checksum" > "$versioned_checksum_file"
    echo "$checksum" > "$stable_checksum_file"

    echo -e "  ${GREEN}✓${NC} Generated SHA256 checksums"
    echo ""
    echo -e "${CYAN}SHA256:${NC} $checksum"
    echo ""

    # Return paths via global variables (bash doesn't support multiple returns well)
    RELEASE_DMG_PATH="$versioned_dmg_path"
    RELEASE_DMG_NAME="$versioned_dmg"
    RELEASE_CHECKSUM_PATH="$versioned_checksum_file"
    RELEASE_CHECKSUM="$checksum"
    # Stable paths for upload
    STABLE_DMG_PATH="$stable_dmg_path"
    STABLE_CHECKSUM_PATH="$stable_checksum_file"
}

# Create tar.gz archive for Tauri updater (required format)
# Tauri v2 updater on macOS expects a .tar.gz containing the .app bundle,
# NOT the DMG. The updater extracts the archive and replaces the running
# .app with the one inside.
create_update_archive() {
    local version=$1
    # $2 is the source_dmg path, but we need the .app bundle instead

    echo -e "${BLUE}Creating update archive for Tauri updater...${NC}"

    local archive_name="malafat-v${version}-macos-arm64.tar.gz"
    local archive_path="$RELEASE_DIR/$archive_name"

    # Find the .app bundle from the Tauri build output
    local app_bundle=""
    local search_paths=(
        "src-tauri/target/release/bundle/macos"
        "src-tauri/target/universal-apple-darwin/release/bundle/macos"
    )

    for search_path in "${search_paths[@]}"; do
        if [[ -d "$search_path" ]]; then
            app_bundle=$(find "$search_path" -maxdepth 1 -name "*.app" -type d | head -1)
            if [[ -n "$app_bundle" && -d "$app_bundle" ]]; then
                break
            fi
        fi
    done

    if [[ -z "$app_bundle" || ! -d "$app_bundle" ]]; then
        echo -e "${RED}Error: No .app bundle found in build output${NC}"
        echo -e "${YELLOW}Expected location: src-tauri/target/**/bundle/macos/*.app${NC}"
        return 1
    fi

    echo -e "  ${CYAN}→${NC} Using .app bundle: $app_bundle"

    # Create tar.gz from the .app bundle (what Tauri updater expects)
    tar -czf "$archive_path" -C "$(dirname "$app_bundle")" "$(basename "$app_bundle")"

    if [[ ! -f "$archive_path" ]]; then
        echo -e "${RED}Error: Failed to create update archive${NC}"
        return 1
    fi

    echo -e "  ${GREEN}✓${NC} Created $archive_path"

    # Return path via global variable
    UPDATE_ARCHIVE_PATH="$archive_path"
    UPDATE_ARCHIVE_NAME="$archive_name"
}

# Sign artifact for Tauri updater
sign_update_artifact() {
    local artifact_path=$1

    if [[ -z "${TAURI_SIGNING_PRIVATE_KEY:-}" ]]; then
        echo -e "  ${YELLOW}⚠${NC} Skipping signing - no private key configured"
        UPDATE_SIGNATURE=""
        return 0
    fi

    echo -e "${BLUE}Signing update artifact...${NC}"

    # Use Tauri CLI to sign the artifact
    # The CLI outputs a message like:
    #   Your file was signed successfully...
    #   Public signature:
    #   <base64 signature>
    #   Make sure to include this...
    # We need to extract ONLY the base64 signature (starts with "dW50cnVzdGVk")
    local cli_output
    cli_output=$(npx @tauri-apps/cli signer sign "$artifact_path" --private-key "$TAURI_SIGNING_PRIVATE_KEY" --password "${TAURI_SIGNING_PRIVATE_KEY_PASSWORD:-}" 2>/dev/null)

    if [[ -z "$cli_output" ]]; then
        echo -e "${RED}Error: Failed to sign artifact${NC}"
        return 1
    fi

    # Extract only the base64 signature line (starts with dW50cnVzdGVk which is base64 for "untrusted comment")
    local signature
    signature=$(echo "$cli_output" | grep -E '^dW50cnVzdGVk' | head -1)

    if [[ -z "$signature" ]]; then
        echo -e "${RED}Error: Could not extract signature from CLI output${NC}"
        echo -e "${YELLOW}CLI output was:${NC}"
        echo "$cli_output"
        return 1
    fi

    echo -e "  ${GREEN}✓${NC} Artifact signed"

    UPDATE_SIGNATURE="$signature"
}

# Generate latest.json manifest for Tauri updater
generate_update_manifest() {
    local version=$1
    local tag="v$version"

    echo -e "${BLUE}Generating update manifest (latest.json)...${NC}"

    local manifest_path="$RELEASE_DIR/latest.json"
    local pub_date
    pub_date=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    local archive_url="https://github.com/$GITHUB_OWNER/$GITHUB_REPO/releases/download/$tag/$UPDATE_ARCHIVE_NAME"

    # Only emit platforms we actually ship a correct, signed artifact for.
    # We build arm64 only, so listing darwin-universal / darwin-x86_64 pointing at
    # the arm64 archive is a lie: signature verifies (same bytes) but the binary
    # won't run on Intel, and older Tauri plugin versions throw on the mismatch.
    # windows-x86_64 is added later by .github/workflows/build-windows.yml.
    cat > "$manifest_path" << EOF
{
  "version": "$version",
  "notes": "Release $tag",
  "pub_date": "$pub_date",
  "platforms": {
    "darwin-aarch64": {
      "signature": "$UPDATE_SIGNATURE",
      "url": "$archive_url"
    }
  }
}
EOF

    if [[ ! -f "$manifest_path" ]]; then
        echo -e "${RED}Error: Failed to create update manifest${NC}"
        return 1
    fi

    echo -e "  ${GREEN}✓${NC} Created $manifest_path"

    UPDATE_MANIFEST_PATH="$manifest_path"
}

# Update website download config file
update_download_config() {
  local version=$1

  echo -e "${BLUE}Updating website download config...${NC}"

  local config_file="src/content/download-config.ts"
  local config_dir="src/content"
  mkdir -p "$config_dir"

  # Calculate mac file size in MB
  local file_size_bytes
  if [[ "$OSTYPE" == "darwin"* ]]; then
    file_size_bytes=$(stat -f%z "$RELEASE_DMG_PATH")
  else
    file_size_bytes=$(stat -c%s "$RELEASE_DMG_PATH")
  fi

  local file_size_mb
  file_size_mb=$(echo "scale=2; $file_size_bytes / 1048576" | bc)
  local mac_file_size="~${file_size_mb} MB"
  local min_macos="${MIN_MACOS:-macOS 12+}"

  # Preserve windows values from existing file (supports both ' and ")
  local win_file_size=""
  local win_sha256=""
  local win_exe_sha256=""

  if [[ -f "$config_file" ]]; then
    # Extract strings like: fileSize: "" or fileSize: ''
    win_file_size=$(sed -n "/windows:/,/^  },/s/.*fileSize: [\"']\([^\"']*\)[\"'].*/\1/p" "$config_file" | head -1 || true)
    win_sha256=$(sed -n "/windows:/,/^  },/s/.*sha256: [\"']\([^\"']*\)[\"'].*/\1/p" "$config_file" | head -1 || true)
    win_exe_sha256=$(sed -n "/windows:/,/^  },/s/.*exeSha256: [\"']\([^\"']*\)[\"'].*/\1/p" "$config_file" | head -1 || true)

    # Safety: if file exists but we couldn't parse, don't wipe it
    if [[ -z "$win_file_size" && -z "$win_sha256" && -z "$win_exe_sha256" ]]; then
      echo -e "  ${YELLOW}⚠${NC} Could not parse existing windows fields. Keeping them empty, but not overwriting file."
      echo -e "    Fix: ensure windows block contains fileSize/sha256/exeSha256 string literals."
      return 0
    fi
  fi

  # Write the exact structure you provided
  cat > "$config_file" << EOF
// Download config with URL templates - version fetched dynamically from GitHub
// Static fields (fileSize, sha256, fallbackVersion) are updated by deploy.sh / deploy.ps1
export interface DownloadConfig {
  githubOwner: string;
  githubRepo: string;
  allReleasesUrl: string;
  fallbackVersion: string;
  releaseNotesUrl?: string;
  getReleaseNotesUrl?: (version: string) => string;
  mac: {
    fileSize: string;
    minVersion: string;
    sha256: string;
    downloadUrl: string;
    getDownloadUrl?: (version: string) => string;
  };
  windows: {
    fileSize: string;
    minVersion: string;
    sha256: string;
    exeSha256?: string;
    msiUrl: string;
    exeUrl: string;
    getMsiUrl?: (version: string) => string;
    getExeUrl?: (version: string) => string;
  };
}

export const DOWNLOAD_CONFIG = {
  githubOwner: "$GITHUB_OWNER",
  githubRepo: "$GITHUB_REPO",
  allReleasesUrl: "https://github.com/$GITHUB_OWNER/$GITHUB_REPO/releases",
  // Fallback version used when GitHub API fails (rate-limited, offline, etc.)
  fallbackVersion: "$version",

  getReleaseNotesUrl: (version: string) =>
    \`https://github.com/$GITHUB_OWNER/$GITHUB_REPO/releases/tag/v\${version}\`,

  mac: {
    fileSize: "$mac_file_size",
    minVersion: "$min_macos",
    sha256: "$RELEASE_CHECKSUM",
    getDownloadUrl: (version: string) =>
      \`https://github.com/$GITHUB_OWNER/$GITHUB_REPO/releases/download/v\${version}/malafat-v\${version}-macos-arm64.dmg\`,
  },

  windows: {
    fileSize: "$win_file_size",
    minVersion: "Windows 10+",
    sha256: "$win_sha256",
    exeSha256: "$win_exe_sha256",
    getMsiUrl: (version: string) =>
      \`https://github.com/$GITHUB_OWNER/$GITHUB_REPO/releases/download/v\${version}/malafat-v\${version}-windows-x64.msi\`,
    getExeUrl: (version: string) =>
      \`https://github.com/$GITHUB_OWNER/$GITHUB_REPO/releases/download/v\${version}/malafat-v\${version}-windows-x64-setup.exe\`,
  },
};

const FALLBACK_VERSION = DOWNLOAD_CONFIG.fallbackVersion;
export const FALLBACK_DOWNLOAD_CONFIG: DownloadConfig = {
  githubOwner: DOWNLOAD_CONFIG.githubOwner,
  githubRepo: DOWNLOAD_CONFIG.githubRepo,
  allReleasesUrl: DOWNLOAD_CONFIG.allReleasesUrl,
  fallbackVersion: FALLBACK_VERSION,
  releaseNotesUrl: DOWNLOAD_CONFIG.getReleaseNotesUrl(FALLBACK_VERSION),
  mac: {
    fileSize: DOWNLOAD_CONFIG.mac.fileSize,
    minVersion: DOWNLOAD_CONFIG.mac.minVersion,
    sha256: DOWNLOAD_CONFIG.mac.sha256,
    downloadUrl: DOWNLOAD_CONFIG.mac.getDownloadUrl(FALLBACK_VERSION),
  },
  windows: {
    fileSize: DOWNLOAD_CONFIG.windows.fileSize,
    minVersion: DOWNLOAD_CONFIG.windows.minVersion,
    sha256: DOWNLOAD_CONFIG.windows.sha256,
    exeSha256: DOWNLOAD_CONFIG.windows.exeSha256,
    msiUrl: DOWNLOAD_CONFIG.windows.getMsiUrl(FALLBACK_VERSION),
    exeUrl: DOWNLOAD_CONFIG.windows.getExeUrl(FALLBACK_VERSION),
  },
};
EOF

  if [[ ! -f "$config_file" ]]; then
    echo -e "${RED}Error: Failed to write download config${NC}"
    exit 1
  fi

  echo -e "  ${GREEN}✓${NC} Updated $config_file"
}

# Generate download config JSON for remote hosting (jsonkeeper, etc.)
generate_download_json() {
    local version=$1
    local tag="v$version"

    echo -e "${BLUE}Generating download config JSON...${NC}"

    # Calculate file size in MB
    local file_size_bytes
    if [[ "$OSTYPE" == "darwin"* ]]; then
        file_size_bytes=$(stat -f%z "$RELEASE_DMG_PATH")
    else
        file_size_bytes=$(stat -c%s "$RELEASE_DMG_PATH")
    fi
    local file_size_mb
    file_size_mb=$(echo "scale=2; $file_size_bytes / 1048576" | bc)
    local file_size="~${file_size_mb} MB"

    local min_macos="${MIN_MACOS:-macOS 12+}"

    # Read existing Windows values from config file if present
    local config_file="src/content/download-config.ts"
    local win_file_size=""
    local win_sha256=""
    local win_exe_sha256=""

    if [[ -f "$config_file" ]]; then
        win_file_size=$(sed -n "/windows:/,/}/s/.*fileSize: '\([^']*\)'.*/\1/p" "$config_file" 2>/dev/null | head -1 || echo "")
        win_sha256=$(sed -n "/windows:/,/}/s/.*sha256: '\([^']*\)'.*/\1/p" "$config_file" 2>/dev/null | head -1 || echo "")
        win_exe_sha256=$(sed -n "/windows:/,/}/s/.*exeSha256: '\([^']*\)'.*/\1/p" "$config_file" 2>/dev/null | head -1 || echo "")
    fi

    # Generate JSON
    local json_output
    json_output=$(cat << EOF
{
  "githubOwner": "$GITHUB_OWNER",
  "githubRepo": "$GITHUB_REPO",
  "allReleasesUrl": "https://github.com/$GITHUB_OWNER/$GITHUB_REPO/releases",
  "fallbackVersion": "$version",
  "releaseNotesUrl": "https://github.com/$GITHUB_OWNER/$GITHUB_REPO/releases/tag/$tag",
  "mac": {
    "fileSize": "$file_size",
    "minVersion": "$min_macos",
    "sha256": "$RELEASE_CHECKSUM",
    "downloadUrl": "https://github.com/$GITHUB_OWNER/$GITHUB_REPO/releases/download/$tag/malafat-$tag-macos-arm64.dmg"
  },
  "windows": {
    "fileSize": "$win_file_size",
    "minVersion": "Windows 10+",
    "sha256": "$win_sha256",
    "exeSha256": "$win_exe_sha256",
    "msiUrl": "https://github.com/$GITHUB_OWNER/$GITHUB_REPO/releases/download/$tag/malafat-$tag-windows-x64.msi",
    "exeUrl": "https://github.com/$GITHUB_OWNER/$GITHUB_REPO/releases/download/$tag/malafat-$tag-windows-x64-setup.exe"
  }
}
EOF
)

    echo ""
    echo -e "${CYAN}========================================${NC}"
    echo -e "${CYAN}  Download Config JSON (copy this)${NC}"
    echo -e "${CYAN}========================================${NC}"
    echo ""
    echo "$json_output"
    echo ""
    echo -e "${CYAN}========================================${NC}"
    echo -e "${YELLOW}Update this at your remote config URL${NC}"
    echo -e "${CYAN}========================================${NC}"
    echo ""
}

# Create GitHub release or upload to existing
create_github_release() {
  local version=$1
  local tag="v$version"

  echo -e "${BLUE}Creating GitHub release...${NC}"

  # Build artifact list - versioned first, then stable
  local artifacts=("$RELEASE_DMG_PATH" "$RELEASE_CHECKSUM_PATH")

  # Add stable artifacts
  [[ -n "${STABLE_DMG_PATH:-}" && -f "$STABLE_DMG_PATH" ]] && artifacts+=("$STABLE_DMG_PATH")
  [[ -n "${STABLE_CHECKSUM_PATH:-}" && -f "$STABLE_CHECKSUM_PATH" ]] && artifacts+=("$STABLE_CHECKSUM_PATH")

  # Add update artifacts
  [[ -n "${UPDATE_MANIFEST_PATH:-}" && -f "$UPDATE_MANIFEST_PATH" ]] && artifacts+=("$UPDATE_MANIFEST_PATH")
  [[ -n "${UPDATE_ARCHIVE_PATH:-}" && -f "$UPDATE_ARCHIVE_PATH" ]] && artifacts+=("$UPDATE_ARCHIVE_PATH")

  # If release exists, just upload & overwrite
  if gh release view "$tag" &> /dev/null; then
    echo -e "  ${YELLOW}→${NC} Release '$tag' already exists - uploading artifacts (--clobber)..."
    gh release upload "$tag" "${artifacts[@]}" --clobber
    echo -e "  ${GREEN}✓${NC} Artifacts uploaded"
    echo ""
    return 0
  fi

  # Otherwise create release (if create fails because it was created concurrently, upload anyway)
  echo -e "  ${CYAN}→${NC} Release '$tag' does not exist - creating..."
  if gh release create "$tag" --title "$tag" --generate-notes "${artifacts[@]}"; then
    echo -e "  ${GREEN}✓${NC} Release created with artifacts"
  else
    echo -e "  ${YELLOW}⚠${NC} Release create failed (maybe created elsewhere). Trying upload..."
    gh release upload "$tag" "${artifacts[@]}" --clobber
    echo -e "  ${GREEN}✓${NC} Artifacts uploaded after fallback"
  fi

  echo ""
}

# Print release URLs
print_release_urls() {
    local version=$1
    local tag="v$version"

    local release_url="https://github.com/$GITHUB_OWNER/$GITHUB_REPO/releases/tag/$tag"
    local versioned_url="https://github.com/$GITHUB_OWNER/$GITHUB_REPO/releases/download/$tag/$RELEASE_DMG_NAME"
    local stable_url="https://github.com/$GITHUB_OWNER/$GITHUB_REPO/releases/latest/download/malafat-macos-arm64.dmg"

    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}  GitHub Release Published! $tag${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo ""
    echo -e "${BOLD}Release Page:${NC}"
    echo -e "  ${CYAN}$release_url${NC}"
    echo ""
    echo -e "${BOLD}SHA256 Checksum:${NC}"
    echo -e "  ${CYAN}$RELEASE_CHECKSUM${NC}"
    echo ""
    echo -e "${GREEN}----------------------------------------${NC}"
    echo -e "${BOLD}Stable Download URL (always latest):${NC}"
    echo -e "  ${CYAN}$stable_url${NC}"
    echo ""
    echo -e "${BOLD}Versioned Download URL (archival):${NC}"
    echo -e "  ${CYAN}$versioned_url${NC}"
    echo ""

    # Show auto-update info if manifest was created
    if [[ -n "${UPDATE_MANIFEST_PATH:-}" ]]; then
        echo -e "${GREEN}----------------------------------------${NC}"
        echo -e "${BOLD}Auto-Update Manifest:${NC}"
        local manifest_url="https://github.com/$GITHUB_OWNER/$GITHUB_REPO/releases/download/$tag/latest.json"
        echo -e "  ${CYAN}$manifest_url${NC}"
        echo ""
        echo -e "${BOLD}Update Archive:${NC}"
        local archive_url="https://github.com/$GITHUB_OWNER/$GITHUB_REPO/releases/download/$tag/$UPDATE_ARCHIVE_NAME"
        echo -e "  ${CYAN}$archive_url${NC}"
        echo ""
    fi

    echo -e "${GREEN}----------------------------------------${NC}"
    echo -e "${BOLD}Windows Build:${NC}"
    echo -e "  ${YELLOW}MSI + EXE installers will be built by GitHub Actions.${NC}"
    echo -e "  They should appear on the release in ~5-10 minutes."
    echo -e "  Monitor: ${CYAN}gh run list --workflow=build-windows.yml${NC}"
    echo ""
    echo -e "${GREEN}----------------------------------------${NC}"
}

# Build macOS and publish to GitHub
build_and_release_mac() {
    local version=$1

     # Load & validate Apple notarization env vars
    load_release_env
    require_release_env

    # Check prerequisites first
    check_release_prerequisites

    # Check if updater signing is available
    local has_updater_signing=false
    if check_updater_signing; then
        has_updater_signing=true
    fi

    # Build macOS app
    build_mac

    # Find the built DMG
    local dmg_path
    dmg_path=$(find_dmg_artifact | tail -1)

    # Prepare release artifacts (both versioned and stable)
    prepare_release_artifacts "$version" "$dmg_path"

    # Create update archive and manifest for auto-updates (if signing configured)
    if [[ "$has_updater_signing" == "true" ]]; then
        create_update_archive "$version" "$RELEASE_DMG_PATH"
        sign_update_artifact "$UPDATE_ARCHIVE_PATH"
        generate_update_manifest "$version"
    else
        echo -e "  ${YELLOW}⚠${NC} Skipping auto-update artifacts (no signing key)"
    fi

    # Tag and push
    tag_and_push "$version"

    # Create GitHub release (uploads both versioned and stable artifacts)
    create_github_release "$version"

    # Print URLs
    print_release_urls "$version"

    echo -e "${GREEN}✓ Release v$version published with stable download URLs${NC}"
}

# Deploy web to main branch
deploy_web() {
    echo -e "${BLUE}Deploying web version to main...${NC}"

    # Build the web version explicitly
    npm run build:web

    # Git operations
    git add .
    git commit -m "Release v$1 (web)" || true
    git push origin main

    echo -e "${GREEN}Web version v$1 deployed to main${NC}"
}

# Build Tauri for Mac (Apple Silicon only)
build_mac() {
    echo -e "${BLUE}Building Tauri for macOS (Apple Silicon)...${NC}"

    # Check if on macOS
    if [[ "$OSTYPE" != "darwin"* ]]; then
        echo -e "${YELLOW}Warning: Building macOS app on non-macOS system may not work${NC}"
    fi

    # Clean build caches to ensure fresh version embedding
    echo -e "${BLUE}Cleaning build caches...${NC}"
    rm -rf dist-desktop dist-web
    cargo clean --manifest-path src-tauri/Cargo.toml

    echo ""
    echo -e "${CYAN}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║  ${BOLD}Tauri Build Process${NC}${CYAN}                                       ║${NC}"
    echo -e "${CYAN}║                                                            ║${NC}"
    echo -e "${CYAN}║  ${NC}This will run in sequence:${CYAN}                                ║${NC}"
    echo -e "${CYAN}║    ${NC}1. Frontend build (Vite) - ~10 seconds${CYAN}                  ║${NC}"
    echo -e "${CYAN}║    ${NC}2. Rust compilation (cargo) - ~2-5 minutes${CYAN}              ║${NC}"
    echo -e "${CYAN}║    ${NC}3. App bundling & code signing - ~1-2 minutes${CYAN}           ║${NC}"
    echo -e "${CYAN}║    ${NC}4. Notarization with Apple - ~2-5 minutes${CYAN}               ║${NC}"
    echo -e "${CYAN}║                                                            ║${NC}"
    echo -e "${CYAN}║  ${YELLOW}⏳ Total expected time: 5-15 minutes${NC}${CYAN}                      ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    echo -e "${YELLOW}▶ Starting Tauri build for aarch64-apple-darwin...${NC}"
    echo ""

    if npm run tauri build; then
        echo ""
        echo -e "${GREEN}╔════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${GREEN}║  ✓ macOS build complete (Apple Silicon)                    ║${NC}"
        echo -e "${GREEN}╚════════════════════════════════════════════════════════════╝${NC}"
    else
        echo ""
        echo -e "${RED}╔════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${RED}║  ✗ Tauri build failed!                                     ║${NC}"
        echo -e "${RED}║                                                            ║${NC}"
        echo -e "${RED}║  Check the error messages above for details.               ║${NC}"
        echo -e "${RED}╚════════════════════════════════════════════════════════════╝${NC}"
        exit 1
    fi

    echo ""
    echo -e "Build output: ${BLUE}src-tauri/target/release/bundle/${NC}"
}

# Build Tauri for Windows (now handled by CI)
build_windows() {
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}  Windows Build - CI Automation${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""
    echo -e "${GREEN}Windows builds are now automated via GitHub Actions!${NC}"
    echo ""
    echo -e "When you publish a macOS release (option 4), GitHub Actions"
    echo -e "automatically builds Windows MSI and EXE installers and"
    echo -e "uploads them to the same release."
    echo ""
    echo -e "${YELLOW}Windows artifacts typically appear 5-10 minutes after release.${NC}"
    echo ""
    echo -e "Monitor progress: ${CYAN}gh run list --workflow=build-windows.yml${NC}"
    echo ""
    echo -e "For local Windows builds, use ${CYAN}deploy.ps1${NC} on a Windows machine."
    echo ""
}

# Main menu
main() {
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}       Malafat Deploy Script          ${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""

  
    # case $version_choice in
        # 1)
        #     ;;
        # 2)
        #     read -p "Enter new version (e.g., 1.0.0): " custom_version
        #     if [[ ! "$custom_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        #         echo -e "${RED}Invalid version format. Use X.Y.Z${NC}"
        #         exit 1
        #     fi
        #     update_version "$custom_version"
        #     current_version="$custom_version"
        #     ;;
        # 3)
        #     echo -e "${YELLOW}Keeping current version: $current_version${NC}"
        #     ;;
        # *)
        #     echo -e "${RED}Invalid option${NC}"
        #     exit 1
        #     ;;
    # esac

    # Get and display current version
    local current_version=$(get_version)

    echo ""
    echo -e "${BLUE}Deploy options:${NC}"
    echo "  1) Deploy to main (web)"
    echo -e "  2) ${GREEN}Build macOS + Publish GitHub Release (DMG)${NC}"
    echo "  3) Cancel"
    # echo "  3) Build Tauri for macOS"
    # echo "  4) Build Tauri for Windows (CI info)"
    echo ""
    read -p "Select deploy option [1-3]: " deploy_choice

    case $deploy_choice in
        1)
            deploy_web "$current_version"
            ;;
    #     2)
    #         build_mac
    #         ;;
    #     3)
    #         build_windows
    #         ;;
        2)
              
            local new_version=$(increment_patch "$current_version")

            echo -e "Current version: ${YELLOW}$current_version${NC}"
            echo -e "Next version:    ${GREEN}$new_version${NC}"
            echo ""

            update_version "$new_version"
            current_version="$new_version"
            build_and_release_mac "$current_version"
            ;;
        3)
            echo -e "${YELLOW}Cancelled${NC}"
            exit 0
            ;;
        *)
            echo -e "${RED}Invalid option${NC}"
            exit 1
            ;;
    esac

    # build_and_release_mac "$current_version"

    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}       Deploy complete! v$current_version${NC}"
    echo -e "${GREEN}========================================${NC}"
}

# Run main
main

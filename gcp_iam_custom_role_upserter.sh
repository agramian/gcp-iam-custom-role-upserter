#!/bin/bash

# Global variable for permissions display limit.
PERMISSIONS_DISPLAY_LIMIT=10

# Function to extract permissions from predefined roles.
get_permissions() {
  local role=$1
  local context_option=""

  if [[ $role != roles/* ]]; then
    # Only include context for custom roles.
    context_option="$CONTEXT"
  fi

  # Get, parse, and split the permissions associated with the role.
  gcloud iam roles describe "$role" $context_option --format="value(includedPermissions)" | tr ';' '\n' | grep -v '^$'
}



# Function to display usage information
usage() {
  printf "GCP IAM custom role upserter\n\n"
  printf "Usage: $0 [-d] [-p PROJECT_ID] [-o ORGANIZATION_ID] YAML_FILE
\t-d \t\t\tDry run mode. Prints the operations that would be performed without executing them.
\t-p PROJECT_ID\t\tOptional project ID to override the one in the YAML file.
\t-o ORGANIZATION_ID\tOptional organization ID to override the one in the YAML file.
"
  exit 1
}

# Default dry run mode and context to empty
DRY_RUN=false
PROJECT_ID_OVERRIDE=""
ORGANIZATION_ID_OVERRIDE=""

# Parse arguments
while getopts ":dp:o:" opt; do
  case $opt in
    d)
      DRY_RUN=true
      ;;
    p)
      PROJECT_ID_OVERRIDE="$OPTARG"
      ;;
    o)
      ORGANIZATION_ID_OVERRIDE="$OPTARG"
      ;;
    \?)
      usage
      ;;
  esac
done
shift $((OPTIND -1))

# Check for minimum required arguments
if [ "$#" -lt 1 ]; then
  usage
fi

# Read the arguments
YAML_FILE=$1

# Check if yq is installed
if ! command -v yq &> /dev/null; then
  echo "yq could not be found. Please install yq to run this script."
  exit 1
fi

# Function to extract single values using yq.
extract_value() {
  local path=$1
  yq e "$path" "$YAML_FILE" 2>/dev/null
}

# Function to extract list values using yq.
extract_list() {
  local path=$1
  yq e "$path | .[]" "$YAML_FILE" 2>/dev/null
}

# Read required fields from YAML file.
ROLE_ID=$(extract_value '.roleId // ""')
TITLE=$(extract_value '.title // ""')
DESCRIPTION=$(extract_value '.description // ""')
STAGE=$(extract_value '.stage // ""')

# Validate required fields.
if [ -z "$TITLE" ] || [ -z "$DESCRIPTION" ] || [ -z "$STAGE" ] || [ -z "$ROLE_ID" ]; then
  echo "Error: 'roleId', 'title', 'description', and 'stage' fields must be defined in the YAML file."
  exit 1
fi

# Read optional fields and validate.
PROJECT_ID=$(extract_value '.projectId // ""')
ORGANIZATION_ID=$(extract_value '.organizationId // ""')

if [ -n "$PROJECT_ID_OVERRIDE" ]; then
  PROJECT_ID="$PROJECT_ID_OVERRIDE"
  ORGANIZATION_ID=""
elif [ -n "$ORGANIZATION_ID_OVERRIDE" ]; then
  ORGANIZATION_ID="$ORGANIZATION_ID_OVERRIDE"
  PROJECT_ID=""
fi

if [ -n "$PROJECT_ID" ] && [ -n "$ORGANIZATION_ID" ]; then
  echo "Error: Both 'projectId' and 'organizationId' are specified. Only one should be specified."
  exit 1
fi

if [ -z "$PROJECT_ID" ] && [ -z "$ORGANIZATION_ID" ]; then
  echo "Error: Either 'projectId' or 'organizationId' must be specified."
  exit 1
fi

# Determine the context (project or organization).
if [ -n "$PROJECT_ID" ]; then
  CONTEXT="--project=$PROJECT_ID"
elif [ -n "$ORGANIZATION_ID" ]; then
  CONTEXT="--organization=$ORGANIZATION_ID"
fi

# Extract list values and handle empty lists.
INCLUDE_PREDEFINED_ROLES=($(extract_list '.predefinedRoles.include // []'))
EXCLUDE_PREDEFINED_ROLES=($(extract_list '.predefinedRoles.exclude // []'))
INCLUDE_PERMISSIONS=($(extract_list '.permissions.include // []'))
EXCLUDE_PERMISSIONS=($(extract_list '.permissions.exclude // []'))

# Collect permissions from included predefined roles.
ALL_PERMISSIONS=()
for role in "${INCLUDE_PREDEFINED_ROLES[@]}"; do
  while IFS= read -r permission; do
    ALL_PERMISSIONS+=("$permission")
  done < <(get_permissions "$role")
done

# Exclude permissions from excluded predefined roles.
for role in "${EXCLUDE_PREDEFINED_ROLES[@]}"; do
  while IFS= read -r permission; do
    ALL_PERMISSIONS=("${ALL_PERMISSIONS[@]/$permission}")
  done < <(get_permissions "$role")
done

# Add included permissions.
for permission in "${INCLUDE_PERMISSIONS[@]}"; do
  ALL_PERMISSIONS+=("$permission")
done

# Remove excluded permissions.
for permission in "${EXCLUDE_PERMISSIONS[@]}"; do
  ALL_PERMISSIONS=("${ALL_PERMISSIONS[@]/$permission}")
done

# Sort and remove duplicate permissions.
UNIQUE_PERMISSIONS=($(printf "%s\n" "${ALL_PERMISSIONS[@]}" | sort -u))

# Function to print permissions with a cap on the number of lines.
print_permissions() {
  local permissions=("${!1}")
  local max_display=$2
  local num_permissions=${#permissions[@]}
  
  echo "Permissions (Total: $num_permissions):"
  if [ "$num_permissions" -gt "$max_display" ]; then
    for ((i=0; i<max_display; i++)); do
      echo "  - ${permissions[i]}"
    done
    echo "  ...and $((num_permissions - max_display)) more permissions."
  else
    for permission in "${permissions[@]}"; do
      echo "  - $permission"
    done
  fi
}

# Display information about what the script will do.
echo ""
echo "Role ID: $ROLE_ID"
echo "Context: $CONTEXT"
echo "Title: $TITLE"
echo "Description: $DESCRIPTION"
echo "Stage: $STAGE"

# Print permissions for the role.
print_permissions UNIQUE_PERMISSIONS[@] "$PERMISSIONS_DISPLAY_LIMIT"

# Create the standard YAML file for gcloud commands.
STANDARD_YAML=$(mktemp)
cat <<EOF > "$STANDARD_YAML"
title: $TITLE
description: $DESCRIPTION
stage: $STAGE
includedPermissions:
$(printf '%s\n' "${UNIQUE_PERMISSIONS[@]}" | sed 's/^/  - /')
EOF

# Check if the role exists and determine action (create or update).
ROLE_EXISTS=$(gcloud iam roles describe "$ROLE_ID" $CONTEXT --format="value(name)" 2>/dev/null && echo "true" || echo "false")
CURRENT_PERMISSIONS=($(get_permissions "$ROLE_ID"))

if [ "$ROLE_EXISTS" = "false" ]; then
  ACTION="create"
else
  ACTION="update"
  # Determine permissions to add/remove.
  PERMISSIONS_TO_ADD=($(comm -13 <(printf "%s\n" "${CURRENT_PERMISSIONS[@]}" | sort) <(printf "%s\n" "${UNIQUE_PERMISSIONS[@]}" | sort)))
  PERMISSIONS_TO_REMOVE=($(comm -23 <(printf "%s\n" "${CURRENT_PERMISSIONS[@]}" | sort) <(printf "%s\n" "${UNIQUE_PERMISSIONS[@]}" | sort)))
  NUM_ADDED=${#PERMISSIONS_TO_ADD[@]}
  NUM_REMOVED=${#PERMISSIONS_TO_REMOVE[@]}
fi

# Perform dry run or actual operation.
if [ "$DRY_RUN" = true ]; then
  echo ""
  echo "Dry run mode enabled. The following changes would be applied:"
  echo ""

  if [ "$ACTION" = "create" ]; then
    echo "Role '$ROLE_ID' will be created."
  else
    echo "Role '$ROLE_ID' will be updated."
    echo "Permissions to be added: $NUM_ADDED"
    echo "Permissions to be removed: $NUM_REMOVED"
  fi

  # Print a limited view of the YAML content.
  print_permissions UNIQUE_PERMISSIONS[@] "$PERMISSIONS_DISPLAY_LIMIT"

  echo ""
  echo "Note: No changes have been applied."
else
  if [ "$ACTION" = "create" ]; then
    gcloud iam roles create "$ROLE_ID" \
      $CONTEXT \
      --file "$STANDARD_YAML"
    echo ""
    echo "Custom role '$ROLE_ID' created successfully."
  else
    gcloud iam roles update "$ROLE_ID" \
      $CONTEXT \
      --file "$STANDARD_YAML"
    echo ""
    echo "Custom role '$ROLE_ID' updated successfully."
  fi
fi

# Remove the temp file.
rm "$STANDARD_YAML"

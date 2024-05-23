#!/usr/bin/env python3
import yaml
import sys
import os

def split_out_branch(repo, branch_to_split, revert=False):
    # Construct the file path
    script_dir = os.path.dirname(os.path.realpath(__file__))
    yaml_file = os.path.join(script_dir, "../core-services/prow/02_config", repo, "_prowconfig.yaml")

    # Check if the file exists
    if not os.path.isfile(yaml_file):
        print(f"YAML file not found: {yaml_file}")
        sys.exit(1)

    with open(yaml_file, 'r') as file:
        config = yaml.safe_load(file)

    if revert:
        new_queries = []
        for query in config['tide']['queries']:
            if branch_to_split in query['includedBranches']:
                if len(query['includedBranches']) == 1:
                    continue  # Remove this query as it's the split-out branch
                else:
                    query['includedBranches'].remove(branch_to_split)
            new_queries.append(query)

        # Add the branch back to the original query
        new_queries[0]['includedBranches'].append(branch_to_split)
        config['tide']['queries'] = new_queries
    else:
        queries = config['tide']['queries'][0]
        new_query = queries.copy()

        if branch_to_split in queries['includedBranches']:
            queries['includedBranches'].remove(branch_to_split)
            new_query['includedBranches'] = [branch_to_split]

            # Add "acknowledge-critical-fixes-only" to labels
            new_query['labels'] = ['approved', 'lgtm', 'acknowledge-critical-fixes-only']

            # Set missingLabels and repos directly
            new_query['missingLabels'] = ['do-not-merge/hold', 'do-not-merge/invalid-owners-file', 'do-not-merge/work-in-progress', 'needs-rebase']
            new_query['repos'] = ['openshift-eng/ocp-build-data']

            config['tide']['queries'].append(new_query)
        else:
            print(f"Branch '{branch_to_split}' not found in the includedBranches.")
            return

    with open(yaml_file, 'w') as file:
        yaml.safe_dump(config, file, default_flow_style=False, sort_keys=False)

    print(f"Updated YAML written to {yaml_file}")

if __name__ == "__main__":
    if len(sys.argv) != 4:
        print("Usage: python script.py <repo> <branch_to_split> <--apply|--revert>")
        sys.exit(1)

    repo = sys.argv[1]
    branch_to_split = sys.argv[2]
    action = sys.argv[3]

    if action == "--apply":
        split_out_branch(repo, branch_to_split)
    elif action == "--revert":
        split_out_branch(repo, branch_to_split, revert=True)
    else:
        print("Invalid action. Use --apply to apply changes or --revert to revert changes.")
        sys.exit(1)


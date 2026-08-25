import yaml
from pathlib import Path
from yaml.loader import SafeLoader

class UniqueKeyLoader(SafeLoader):
    def construct_mapping(self, node, deep=False):
        if not isinstance(node, yaml.MappingNode):
            return super().construct_mapping(node, deep=deep)
        mapping = {}
        for key_node, value_node in node.value:
            key = self.construct_object(key_node, deep=deep)
            if key in mapping:
                raise ValueError(f"Duplicate key found: {key}")
            mapping[key] = self.construct_object(value_node, deep=deep)
        return super().construct_mapping(node, deep=deep)

def test_project_keys_consistency():
    config_path = Path(__file__).parent.parent / "agent-orchestrator.yaml"
    assert config_path.exists(), "agent-orchestrator.yaml does not exist"
    
    with open(config_path, "r") as f:
        # First load with SafeLoader to check name consistency
        f.seek(0)
        config = yaml.safe_load(f)
        
    projects = config.get("projects", {})
    for config_key, project in projects.items():
        path = project.get("path", "")
        project_basename = Path(path).name
        if config_key == project_basename:
            continue  # Convention satisfied - exempt
            
        name = project.get("name")
        assert name == config_key, f"Project name '{name}' does not match configKey '{config_key}' (required because path basename '{project_basename}' does not match configKey)"

def test_no_duplicate_yaml_keys():
    config_path = Path(__file__).parent.parent / "agent-orchestrator.yaml"
    assert config_path.exists(), "agent-orchestrator.yaml does not exist"
    
    with open(config_path, "r") as f:
        try:
            yaml.load(f, Loader=UniqueKeyLoader)
        except ValueError as e:
            assert False, str(e)

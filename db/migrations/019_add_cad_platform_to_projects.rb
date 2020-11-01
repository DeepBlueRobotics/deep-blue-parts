Sequel.migration do
  change do
    alter_table(:projects) do
      add_column :cad_platform, String, :default => "SOLIDWORKS", :null => false
    end
  end
end

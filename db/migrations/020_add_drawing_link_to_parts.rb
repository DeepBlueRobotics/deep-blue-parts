Sequel.migration do
  change do
    alter_table(:parts) do
      add_column :drawing_link, String, :default => "", :null => false
    end
  end
end

import React, { useState } from 'react';

interface InputProps {
  placeholder?: string;
  onChange: (value: string) => void;
}

// TODO: Add validation
export function Input({ placeholder, onChange }: InputProps) {
  const [value, setValue] = useState('');
  
  function handleChange(e: React.ChangeEvent<HTMLInputElement>) {
    setValue(e.target.value);
    onChange(e.target.value);
  }
  
  return <input value={value} onChange={handleChange} placeholder={placeholder} />;
}
